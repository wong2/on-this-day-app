import Photos
import Observation
import Vision
import UIKit

@MainActor
@Observable
final class PhotoLibrary: NSObject, PHPhotoLibraryChangeObserver {
    private(set) var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var years: [MemoryYear] = []
    private(set) var isLoading = false
    private(set) var today = Date()
    private(set) var isCheckingScreenshots = false
    private(set) var uncheckedPhotoCount = 0
    var filterAIScreenshots = UserDefaults.standard.object(forKey: "filterAIScreenshots") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(filterAIScreenshots, forKey: "filterAIScreenshots")
            refresh(force: true)
        }
    }
    @ObservationIgnored private var screenshotScores = UserDefaults.standard.dictionary(forKey: "screenshotScores") as? [String: Float] ?? [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadedDay: Date?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isObserving = false

    var canRead: Bool { authorization == .authorized || authorization == .limited }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func requestAccess() async {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        refresh(force: true)
    }

    func refresh(force: Bool = false) {
        let previous = authorization
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        today = Date()
        let day = MemoryIndex.calendar().startOfDay(for: today)
        guard canRead else {
            if isObserving {
                PHPhotoLibrary.shared().unregisterChangeObserver(self)
                isObserving = false
            }
            loadTask?.cancel()
            generation += 1
            years = []
            loadedDay = nil
            isLoading = false
            isCheckingScreenshots = false
            return
        }
        if !isObserving {
            PHPhotoLibrary.shared().register(self)
            isObserving = true
        }
        guard force || previous != authorization || loadedDay != day else { return }
        loadTask?.cancel()
        generation += 1
        let requestGeneration = generation
        isLoading = true
        let date = today
        let calendar = MemoryIndex.calendar()
        let filterAI = filterAIScreenshots
        isCheckingScreenshots = false
        uncheckedPhotoCount = 0
        loadTask = Task {
            let result = await Self.fetchYears(today: date, calendar: calendar)
            guard !Task.isCancelled, requestGeneration == generation else { return }
            years = filterAI ? result.compactMap { group in
                let photos = group.photos.filter { !MemoryIndex.isLikelyScreenshot(confidence: screenshotScores[$0.classificationKey]) }
                return photos.isEmpty ? nil : MemoryYear(year: group.year, photos: photos)
            } : result
            loadedDay = day
            isLoading = false
            guard filterAI else { return }
            isCheckingScreenshots = true
            for photo in result.flatMap(\.photos) {
                guard !Task.isCancelled, requestGeneration == generation else { return }
                if screenshotScores[photo.classificationKey] != nil { continue }
                let score = await ScreenshotClassifier.confidence(for: photo.id)
                guard !Task.isCancelled, requestGeneration == generation else { return }
                if let score {
                    screenshotScores[photo.classificationKey] = score
                    UserDefaults.standard.set(screenshotScores, forKey: "screenshotScores")
                    if MemoryIndex.isLikelyScreenshot(confidence: score) {
                        years = years.compactMap { group in
                            let photos = group.photos.filter { $0.id != photo.id }
                            return photos.isEmpty ? nil : MemoryYear(year: group.year, photos: photos)
                        }
                    }
                } else {
                    uncheckedPhotoCount += 1
                }
            }
            isCheckingScreenshots = false
        }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in self?.refresh(force: true) }
    }

    @concurrent
    private static func fetchYears(today: Date, calendar: Calendar) async -> [MemoryYear] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var grouped: [Int: [MemoryPhoto]] = [:]
        for index in 0..<assets.count {
            if Task.isCancelled { return [] }
            autoreleasepool {
                let asset = assets.object(at: index)
                guard let year = MemoryIndex.matchingYear(
                    for: asset.creationDate,
                    isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                    today: today,
                    calendar: calendar
                ), let date = asset.creationDate else { return }
                guard !PHAssetResource.assetResources(for: asset).contains(where: {
                          MemoryIndex.hasScreenshotFilename($0.originalFilename)
                      }) else { return }
                let coordinate = asset.location.flatMap {
                    MemoryCoordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
                }
                grouped[year, default: []].append(MemoryPhoto(id: asset.localIdentifier, date: date, modificationDate: asset.modificationDate, coordinate: coordinate))
            }
        }
        return MemoryIndex.sortedGroups(grouped)
    }
}

nonisolated enum ScreenshotClassifier {
    @concurrent
    static func confidence(for id: String) async -> Float? {
        guard !Task.isCancelled,
              let image = await ScreenshotImageRequest().image(for: id),
              !Task.isCancelled else { return nil }
        return confidence(in: image.cgImage, orientation: image.orientation)
    }

    static func confidence(in image: CGImage, orientation: CGImagePropertyOrientation = .up) -> Float? {
        let request = VNClassifyImageRequest()
        request.revision = VNClassifyImageRequestRevision2
        do {
            guard try request.supportedIdentifiers().contains("screenshot") else { return nil }
            try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
            return request.results?.first(where: { $0.identifier == "screenshot" })?.confidence
        } catch {
            return nil
        }
    }
}

private nonisolated struct ClassificationImage: Sendable {
    let cgImage: CGImage
    let orientation: CGImagePropertyOrientation
}

@MainActor
private final class ScreenshotImageRequest {
    private var continuation: CheckedContinuation<ClassificationImage?, Never>?
    private var requestID: PHImageRequestID?
    private var timeout: Task<Void, Never>?

    func image(for id: String) async -> ClassificationImage? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled,
                      let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
                    finish(nil)
                    return
                }
                let options = PHImageRequestOptions()
                options.deliveryMode = .highQualityFormat
                options.resizeMode = .fast
                options.isNetworkAccessAllowed = true
                requestID = PHImageManager.default().requestImage(
                    for: asset, targetSize: CGSize(width: 512, height: 512),
                    contentMode: .aspectFit, options: options
                ) { [weak self] image, info in
                    if info?[PHImageResultIsDegradedKey] as? Bool == true { return }
                    let result: ClassificationImage?
                    if let image, let cgImage = image.cgImage {
                        let orientation: CGImagePropertyOrientation
                        switch image.imageOrientation {
                        case .up: orientation = .up
                        case .down: orientation = .down
                        case .left: orientation = .left
                        case .right: orientation = .right
                        case .upMirrored: orientation = .upMirrored
                        case .downMirrored: orientation = .downMirrored
                        case .leftMirrored: orientation = .leftMirrored
                        case .rightMirrored: orientation = .rightMirrored
                        @unknown default: orientation = .up
                        }
                        result = ClassificationImage(cgImage: cgImage, orientation: orientation)
                    } else {
                        result = nil
                    }
                    Task { @MainActor in self?.finish(result) }
                }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    self?.finish(nil)
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(nil) }
        }
    }

    private func finish(_ image: ClassificationImage?) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        if let requestID { PHImageManager.default().cancelImageRequest(requestID) }
        requestID = nil
        continuation.resume(returning: image)
    }
}

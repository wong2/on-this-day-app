import Photos
import SwiftUI
import MapKit

@MainActor
@Observable
final class PhotoLoader {
    var image: UIImage?
    var failed = false
    var progress: Double = 0
    private var requestID: PHImageRequestID?
    private var token = UUID()
    private let manager = PHImageManager.default()

    func load(id: String, size: CGSize, preservingImage: Bool = false) {
        cancel()
        if !preservingImage { image = nil }
        failed = false
        progress = 0
        let currentToken = token
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            failed = true
            return
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.progressHandler = { [weak self] progress, _, _, _ in
            Task { @MainActor in
                guard let self, self.token == currentToken else { return }
                self.progress = progress
            }
        }
        requestID = manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { [weak self] image, info in
            let cancelled = info?[PHImageCancelledKey] as? Bool == true
            let error = info?[PHImageErrorKey] != nil
            let degraded = info?[PHImageResultIsDegradedKey] as? Bool == true
            Task { @MainActor in
                guard let self, self.token == currentToken, !cancelled else { return }
                if let image { self.image = image }
                if !degraded { self.failed = self.image == nil && (error || image == nil) }
            }
        }
    }

    func cancel() {
        token = UUID()
        if let requestID { manager.cancelImageRequest(requestID) }
        requestID = nil
    }
}

struct PhotoCityLabel: View {
    let city: String?

    var body: some View {
        VStack(spacing: 0) {
            if let city {
                Label(city, systemImage: "mappin.and.ellipse")
                    .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel("Photo location: \(city)")
            }
        }
    }
}

@MainActor
@Observable
final class PhotoCityStore {
    static let shared = PhotoCityStore()
    private var cities: [MemoryCoordinate: String] = [:]
    @ObservationIgnored private var insertionOrder: [MemoryCoordinate] = []
    @ObservationIgnored private let resolve: (MemoryCoordinate) async -> String?

    init(resolve: ((MemoryCoordinate) async -> String?)? = nil) {
        self.resolve = resolve ?? { await PhotoCityRequest().city(for: $0) }
    }

    func cachedCity(for coordinate: MemoryCoordinate?) -> String? {
        coordinate.flatMap { cities[$0] }
    }

    func load(_ coordinates: [MemoryCoordinate]) async {
        var visited = Set<MemoryCoordinate>()
        for coordinate in coordinates {
            guard !Task.isCancelled else { return }
            guard visited.insert(coordinate).inserted, cities[coordinate] == nil else { continue }
            let city = await resolve(coordinate)
            guard !Task.isCancelled else { return }
            guard let city, !city.isEmpty else { continue }
            if insertionOrder.count >= 100 {
                cities.removeValue(forKey: insertionOrder.removeFirst())
            }
            cities[coordinate] = city
            insertionOrder.append(coordinate)
        }
    }
}

@MainActor
private final class PhotoCityRequest {
    private var cancelRequest: (() -> Void)?

    func city(for coordinate: MemoryCoordinate) async -> String? {
        guard !Task.isCancelled else { return nil }
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let result: String? = await withTaskCancellationHandler {
            do {
                if #available(iOS 26.0, *) {
                    guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
                    request.preferredLocale = Locale(identifier: "en_US")
                    cancelRequest = { request.cancel() }
                    return try await request.mapItems.first?.addressRepresentations?.cityName
                } else {
                    let geocoder = CLGeocoder()
                    cancelRequest = { geocoder.cancelGeocode() }
                    return try await geocoder.reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "en_US")).first?.locality
                }
            } catch {
                return nil
            }
        } onCancel: {
            Task { @MainActor in self.cancelRequest?() }
        }
        cancelRequest = nil
        guard !Task.isCancelled, let result, !result.isEmpty else { return nil }
        return result
    }
}

struct PhotoView: View {
    let photo: MemoryPhoto
    let isActive: Bool
    let previous: () -> Void
    let next: () -> Void
    let zoomChanged: (Bool) -> Void
    @Environment(\.displayScale) private var scale
    @State private var loader = PhotoLoader()
    @State private var requestedDetail = false
    @State private var isZoomed = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let image = loader.image {
                    ZoomablePhoto(
                        image: image,
                        label: "Photo from \(photo.date.formatted(date: .complete, time: .shortened))",
                        previous: previous, next: next,
                        zoomChanged: { zoomed in
                            isZoomed = zoomed
                            zoomChanged(zoomed)
                            if zoomed && !requestedDetail {
                                requestedDetail = true
                                let pixels = CGSize(width: geometry.size.width * scale * 3, height: geometry.size.height * scale * 3)
                                let factor = min(1, 4096 / max(pixels.width, pixels.height))
                                loader.load(id: photo.id, size: CGSize(width: pixels.width * factor, height: pixels.height * factor), preservingImage: true)
                            }
                        }
                    )
                }
                if loader.failed {
                    VStack(spacing: 12) {
                        Image(systemName: "icloud.slash").font(.title2)
                        Text("Couldn’t load this photo").font(.headline)
                        Text("Check your connection and try again.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Try Again") { load(in: geometry.size) }
                            .buttonStyle(.bordered)
                    }
                    .padding()
                } else if loader.image == nil {
                    VStack(spacing: 10) {
                        ProgressView().tint(.white)
                        if loader.progress > 0 {
                            Text("Downloading from iCloud · \(Int(loader.progress * 100))%")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .accessibilityAction(named: "Previous photo", previous)
            .accessibilityAction(named: "Next photo", next)
            .task(id: LoadKey(id: photo.id, active: isActive, size: geometry.size)) {
                if isActive { load(in: geometry.size) } else {
                    loader.cancel()
                    loader.image = nil
                    requestedDetail = false
                    if isZoomed { isZoomed = false; zoomChanged(false) }
                }
            }
            .onDisappear {
                loader.cancel()
                loader.image = nil
                requestedDetail = false
                if isZoomed { isZoomed = false; zoomChanged(false) }
            }
        }
    }

    private func load(in size: CGSize) {
        loader.load(id: photo.id, size: CGSize(width: size.width * scale, height: size.height * scale))
    }

    private struct LoadKey: Equatable {
        let id: String
        let active: Bool
        let size: CGSize
    }
}

private struct ZoomablePhoto: UIViewRepresentable {
    let image: UIImage
    let label: String
    let previous: () -> Void
    let next: () -> Void
    let zoomChanged: (Bool) -> Void

    func makeUIView(context: Context) -> PhotoZoomScrollView {
        let view = PhotoZoomScrollView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: PhotoZoomScrollView, context: Context) {
        view.imageView.image = image
        view.imageView.accessibilityLabel = label
        view.previous = previous
        view.nextPhoto = next
        view.zoomChanged = zoomChanged
        view.setNeedsLayout()
    }
}

final class PhotoZoomScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let imageView = UIImageView()
    var previous: () -> Void = {}
    var nextPhoto: () -> Void = {}
    var zoomChanged: (Bool) -> Void = { _ in }
    private var viewport = CGSize.zero
    private var reportedZoom = false
    private let doubleTap = UITapGestureRecognizer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bouncesZoom = true
        panGestureRecognizer.isEnabled = false
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        addSubview(imageView)
        doubleTap.numberOfTapsRequired = 2
        doubleTap.numberOfTouchesRequired = 1
        doubleTap.delegate = self
        doubleTap.addTarget(self, action: #selector(doubleTapped))
        addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.numberOfTouchesRequired = 1
        tap.require(toFail: doubleTap)
        if let pinchGestureRecognizer { tap.require(toFail: pinchGestureRecognizer) }
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, let image = imageView.image else { return }
        if viewport != bounds.size || imageView.bounds.isEmpty {
            viewport = bounds.size
            setZoomScale(1, animated: false)
            if reportedZoom {
                Task { @MainActor [weak self] in self?.reportZoom(false) }
            }
            let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
            imageView.frame = CGRect(origin: .zero, size: CGSize(width: image.size.width * fit, height: image.size.height * fit))
            contentSize = imageView.bounds.size
        }
        centerImage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        reportZoom(true)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        panGestureRecognizer.isEnabled = zoomScale > 1.01
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        reportZoom(scale > 1.01)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        gestureRecognizer !== doubleTap || zoomScale > 1.01
    }

    func resetZoom(animated: Bool) {
        setZoomScale(minimumZoomScale, animated: animated)
        if !animated { reportZoom(false) }
    }

    @objc private func doubleTapped() {
        guard zoomScale > 1.01 else { return }
        resetZoom(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func centerImage() {
        imageView.center = CGPoint(x: max(contentSize.width, bounds.width) / 2, y: max(contentSize.height, bounds.height) / 2)
    }

    private func reportZoom(_ zoomed: Bool) {
        guard reportedZoom != zoomed else { return }
        reportedZoom = zoomed
        zoomChanged(zoomed)
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard zoomScale <= 1.01, !isZooming else { return }
        if gesture.location(in: self).x - bounds.minX < bounds.width * 0.35 { previous() } else { nextPhoto() }
    }
}

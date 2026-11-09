import XCTest
import UIKit
@testable import OnThisDay

nonisolated final class MemoryIndexTests: XCTestCase {
    private let calendar = MemoryIndex.calendar(timeZone: TimeZone(secondsFromGMT: 0)!)

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testMatchesOnlySameDayInPastYearsAndExcludesScreenshots() {
        let today = date(2026, 11, 8)
        XCTAssertEqual(MemoryIndex.matchingYear(for: date(2024, 11, 8), isScreenshot: false, today: today, calendar: calendar), 2024)
        for candidate in [date(2026, 11, 8), date(2027, 11, 8), date(2024, 11, 7), date(2024, 10, 8)] {
            XCTAssertNil(MemoryIndex.matchingYear(for: candidate, isScreenshot: false, today: today, calendar: calendar))
        }
        XCTAssertNil(MemoryIndex.matchingYear(for: date(2024, 11, 8), isScreenshot: true, today: today, calendar: calendar))
        XCTAssertNil(MemoryIndex.matchingYear(for: nil, isScreenshot: false, today: today, calendar: calendar))
    }

    func testGroupsSkipEmptyYearsAndSortNewestYearFirstPhotosChronologically() {
        let early = MemoryPhoto(id: "a", date: date(2024, 11, 8, hour: 8))
        let late = MemoryPhoto(id: "b", date: date(2024, 11, 8, hour: 18))
        let older = MemoryPhoto(id: "c", date: date(2020, 11, 8))
        let groups = MemoryIndex.sortedGroups([2024: [late, early], 2023: [], 2020: [older]])
        XCTAssertEqual(groups.map(\.year), [2024, 2020])
        XCTAssertEqual(groups.first?.photos, [early, late])
    }

    func testLeapDayDoesNotFallBackToFebruary28() {
        let today = date(2028, 2, 29)
        XCTAssertEqual(MemoryIndex.matchingYear(for: date(2024, 2, 29), isScreenshot: false, today: today, calendar: calendar), 2024)
        XCTAssertNil(MemoryIndex.matchingYear(for: date(2025, 2, 28), isScreenshot: false, today: today, calendar: calendar))
    }

    func testCurrentTimeZoneDeterminesDayAndYearBoundary() {
        let local = MemoryIndex.calendar(timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
        let today = date(2026, 12, 31, hour: 18)
        let photo = date(2024, 12, 31, hour: 18)
        XCTAssertEqual(MemoryIndex.matchingYear(for: photo, isScreenshot: false, today: today, calendar: local), 2025)
        XCTAssertEqual(MemoryIndex.matchingYear(for: photo, isScreenshot: false, today: today, calendar: calendar), 2024)
    }

    func testScreenshotFilenameRequiresAnExplicitPrefixAndNumber() {
        for name in ["Screenshot_2024-01-02.png", "Screen Shot 2024-01-02 at 12.00.png", "截屏2024-01-02.png", "截图_20240102.jpg"] {
            XCTAssertTrue(MemoryIndex.hasScreenshotFilename(name), name)
        }
        for name in ["IMG_1234.PNG", "DSC001.jpg", "screenshot of my holiday.jpg", "my-screenshot-2024.png"] {
            XCTAssertFalse(MemoryIndex.hasScreenshotFilename(name), name)
        }
    }

    func testPhotoCoordinatesValidateBoundsWithoutRejectingZero() {
        XCTAssertNotNil(MemoryCoordinate(latitude: 0, longitude: 0))
        XCTAssertNotNil(MemoryCoordinate(latitude: -90, longitude: 180))
        XCTAssertNil(MemoryCoordinate(latitude: 91, longitude: 0))
        XCTAssertNil(MemoryCoordinate(latitude: 0, longitude: -181))
        XCTAssertNil(MemoryCoordinate(latitude: .nan, longitude: 0))
        XCTAssertNil(MemoryCoordinate(latitude: 0, longitude: .infinity))
    }

    func testAIOnlyExcludesHighConfidenceScreenshotsAndFailsOpen() {
        XCTAssertTrue(MemoryIndex.isLikelyScreenshot(confidence: 0.9))
        XCTAssertTrue(MemoryIndex.isLikelyScreenshot(confidence: 1))
        for confidence: Float? in [nil, 0, 0.89, .nan, .infinity, 1.1] {
            XCTAssertFalse(MemoryIndex.isLikelyScreenshot(confidence: confidence))
        }
        let original = MemoryPhoto(id: "a", date: date(2024, 11, 8))
        let edited = MemoryPhoto(id: "a", date: original.date, modificationDate: date(2025, 11, 8))
        XCTAssertNotEqual(original.classificationKey, edited.classificationKey)
    }

    @MainActor
    func testShareExportPreservesImageBytesAndCleansUp() async throws {
        let data = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 32, height: 48)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
        }.pngData())
        let first = try await SharedPhotoFile.create(data: data, typeIdentifier: "public.png")
        let second = try await SharedPhotoFile.create(data: data, typeIdentifier: "public.png")
        defer { first.remove(); second.remove() }
        XCTAssertEqual(first.url.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: first.url), data)
        XCTAssertNotEqual(first.url, second.url)
        first.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
    }

    @MainActor
    func testShareExportRejectsMissingDataAndCancelledWork() async throws {
        do {
            _ = try await SharedPhotoFile.create(data: Data(), typeIdentifier: "public.png")
            XCTFail("Empty data must not open a share sheet")
        } catch {}
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SharedPhotoFile.create(data: Data([1]), typeIdentifier: "public.png")
        }
        do {
            let file = try await task.value
            file.remove()
            XCTFail("Cancelled preparation must not produce a shared file")
        } catch is CancellationError {} catch {
            XCTFail("Expected cancellation, got \(error)")
        }
    }

    @MainActor
    func testSharingUnavailableAssetShowsRecoverableError() {
        let loader = PhotoShareLoader()
        loader.prepare(id: "missing-test-asset")
        XCTAssertNotNil(loader.errorMessage)
        XCTAssertFalse(loader.isPreparing)
        XCTAssertNil(loader.file)
        loader.cancelPreparation()
        loader.finishSharing()
        XCTAssertNil(loader.file)
    }

    @MainActor
    func testCityCachePrefetchesInOrderAndReturnsCachedNamesSynchronously() async throws {
        let current = try XCTUnwrap(MemoryCoordinate(latitude: 1, longitude: 1))
        let next = try XCTUnwrap(MemoryCoordinate(latitude: 2, longitude: 2))
        let unknown = try XCTUnwrap(MemoryCoordinate(latitude: 3, longitude: 3))
        var requests: [MemoryCoordinate] = []
        let store = PhotoCityStore { coordinate in
            requests.append(coordinate)
            return coordinate == current ? "Current City" : "Next City"
        }
        await store.load([current, next, current])
        XCTAssertEqual(requests, [current, next])
        XCTAssertEqual(store.cachedCity(for: next), "Next City")
        XCTAssertEqual(store.cachedCity(for: current), "Current City")
        XCTAssertNil(store.cachedCity(for: unknown))
        XCTAssertNil(store.cachedCity(for: nil))
        await store.load([next, current])
        XCTAssertEqual(requests.count, 2)
    }

    @MainActor
    func testCancelledCityLookupDoesNotCacheLateResultOrContinuePrefetch() async throws {
        let current = try XCTUnwrap(MemoryCoordinate(latitude: 1, longitude: 1))
        let next = try XCTUnwrap(MemoryCoordinate(latitude: 2, longitude: 2))
        var requests = 0
        let store = PhotoCityStore { _ in
            requests += 1
            withUnsafeCurrentTask { $0?.cancel() }
            return "Late Result"
        }
        let task = Task { await store.load([current, next]) }
        await task.value
        XCTAssertEqual(requests, 1)
        XCTAssertNil(store.cachedCity(for: current))
        XCTAssertNil(store.cachedCity(for: next))
    }

    @MainActor
    func testFailedCityLookupCanRetryAndCacheStaysBounded() async throws {
        let current = try XCTUnwrap(MemoryCoordinate(latitude: 0, longitude: 0))
        var shouldFail = true
        let store = PhotoCityStore { _ in shouldFail ? nil : "City" }
        await store.load([current])
        XCTAssertNil(store.cachedCity(for: current))
        shouldFail = false
        await store.load([current])
        XCTAssertEqual(store.cachedCity(for: current), "City")
        let coordinates = (1...100).compactMap { MemoryCoordinate(latitude: 0, longitude: Double($0)) }
        await store.load(coordinates)
        XCTAssertNil(store.cachedCity(for: current))
        XCTAssertEqual(store.cachedCity(for: coordinates.last), "City")
    }

    @MainActor
    func testResetZoomRestoresPagingWithoutAdvancingPhoto() {
        let view = PhotoZoomScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        view.imageView.image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 200)).image { _ in }
        view.setNeedsLayout()
        view.layoutIfNeeded()
        var zoomed = false
        var photoMoves = 0
        view.zoomChanged = { zoomed = $0 }
        view.previous = { photoMoves += 1 }
        view.nextPhoto = { photoMoves += 1 }
        view.scrollViewWillBeginZooming(view, with: view.imageView)
        view.setZoomScale(3, animated: false)
        view.contentOffset = CGPoint(x: 100, y: 100)
        XCTAssertTrue(zoomed)
        view.resetZoom(animated: false)
        XCTAssertEqual(view.zoomScale, 1)
        XCTAssertFalse(view.panGestureRecognizer.isEnabled)
        XCTAssertFalse(zoomed)
        XCTAssertEqual(photoMoves, 0)
        XCTAssertEqual(view.contentOffset, .zero)
    }

    @MainActor
    func testZoomKeepsScaleWhenHigherResolutionArrivesAndResetsOnResize() {
        let view = PhotoZoomScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 200)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 200))
        }
        view.imageView.image = image
        view.setNeedsLayout()
        view.layoutIfNeeded()
        XCTAssertFalse(view.panGestureRecognizer.isEnabled)
        view.setZoomScale(2, animated: false)
        XCTAssertTrue(view.panGestureRecognizer.isEnabled)
        view.imageView.image = image
        view.setNeedsLayout()
        view.layoutIfNeeded()
        XCTAssertEqual(view.zoomScale, 2)
        view.frame.size = CGSize(width: 600, height: 390)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        XCTAssertEqual(view.zoomScale, 1)
        XCTAssertFalse(view.panGestureRecognizer.isEnabled)
    }
}

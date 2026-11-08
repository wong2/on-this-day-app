import Foundation

nonisolated struct MemoryPhoto: Identifiable, Hashable, Sendable {
    let id: String
    let date: Date
    var modificationDate: Date? = nil
    var coordinate: MemoryCoordinate? = nil

    var classificationKey: String {
        "vision2-v1:\(id):\((modificationDate ?? date).timeIntervalSince1970)"
    }
}

nonisolated struct MemoryCoordinate: Hashable, Sendable {
    let latitude: Double
    let longitude: Double

    init?(latitude: Double, longitude: Double) {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        self.latitude = latitude
        self.longitude = longitude
    }
}

nonisolated struct MemoryYear: Identifiable, Equatable, Sendable {
    let year: Int
    let photos: [MemoryPhoto]
    var id: Int { year }
}

nonisolated enum MemoryIndex {
    static func isLikelyScreenshot(confidence: Float?) -> Bool {
        guard let confidence, confidence.isFinite else { return false }
        return confidence >= 0.9 && confidence <= 1
    }

    static func hasScreenshotFilename(_ filename: String) -> Bool {
        let name = (filename as NSString).deletingPathExtension.lowercased()
        return name.range(of: #"^(screenshot|screen[ _-]shot|截屏|截图)[ _-]*[0-9]"#, options: .regularExpression) != nil
    }

    static func matchingYear(for date: Date?, isScreenshot: Bool, today: Date, calendar: Calendar) -> Int? {
        guard !isScreenshot, let date else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let current = calendar.dateComponents([.year, .month, .day], from: today)
        guard let year = parts.year, let currentYear = current.year,
              year < currentYear, parts.month == current.month, parts.day == current.day else {
            return nil
        }
        return year
    }

    static func sortedGroups(_ photos: [Int: [MemoryPhoto]]) -> [MemoryYear] {
        photos.keys.sorted(by: >).compactMap { year in
            guard let items = photos[year], !items.isEmpty else { return nil }
            return MemoryYear(year: year, photos: items.sorted {
                $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
            })
        }
    }

    static func calendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}

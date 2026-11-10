import Foundation
import Observation
import UserNotifications

@MainActor
protocol ReminderNotificationClient {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func remove()
}

@MainActor
struct SystemReminderNotifications: ReminderNotificationClient {
    private let center = UNUserNotificationCenter.current()

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }

    func remove() {
        center.removePendingNotificationRequests(withIdentifiers: [DailyReminder.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [DailyReminder.identifier])
    }
}

@MainActor
@Observable
final class DailyReminder {
    nonisolated static let identifier = "daily-memory-reminder"
    private(set) var isEnabled: Bool
    private(set) var hour: Int
    private(set) var minute: Int
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var isUpdating = false
    var errorMessage: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let notifications: any ReminderNotificationClient

    init(defaults: UserDefaults = .standard, notifications: any ReminderNotificationClient = SystemReminderNotifications()) {
        self.defaults = defaults
        self.notifications = notifications
        isEnabled = defaults.bool(forKey: "dailyReminderEnabled")
        let savedHour = defaults.object(forKey: "dailyReminderHour") as? Int ?? 10
        let savedMinute = defaults.object(forKey: "dailyReminderMinute") as? Int ?? 0
        hour = (0...23).contains(savedHour) ? savedHour : 10
        minute = (0...59).contains(savedMinute) ? savedMinute : 0
    }

    var time: Date {
        Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 15, hour: hour, minute: minute)) ?? .now
    }

    private var isAuthorized: Bool {
        authorization == .authorized || authorization == .provisional || authorization == .ephemeral
    }

    static func request(hour: Int, minute: Int) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "On This Day"
        content.body = "Take a moment to revisit your memories."
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: hour, minute: minute), repeats: true)
        return UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isUpdating else { return }
        isUpdating = true
        errorMessage = nil
        defer { isUpdating = false }
        if !enabled {
            notifications.remove()
            isEnabled = false
            defaults.set(false, forKey: "dailyReminderEnabled")
            return
        }
        do {
            authorization = await notifications.authorizationStatus()
            if authorization == .notDetermined {
                _ = try await notifications.requestAuthorization()
                authorization = await notifications.authorizationStatus()
            }
            guard isAuthorized else { return }
            try await notifications.add(Self.request(hour: hour, minute: minute))
            isEnabled = true
            defaults.set(true, forKey: "dailyReminderEnabled")
        } catch {
            errorMessage = "Couldn’t enable the reminder. Please try again."
        }
    }

    func setTime(_ time: Date) async {
        guard !isUpdating else { return }
        isUpdating = true
        errorMessage = nil
        defer { isUpdating = false }
        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
        guard let hour = components.hour, let minute = components.minute else { return }
        do {
            authorization = await notifications.authorizationStatus()
            if isEnabled && isAuthorized {
                try await notifications.add(Self.request(hour: hour, minute: minute))
            } else if isEnabled {
                notifications.remove()
            }
            self.hour = hour
            self.minute = minute
            defaults.set(hour, forKey: "dailyReminderHour")
            defaults.set(minute, forKey: "dailyReminderMinute")
        } catch {
            errorMessage = "Couldn’t change the reminder time. Please try again."
        }
    }

    func refresh() async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        authorization = await notifications.authorizationStatus()
        guard isEnabled && isAuthorized else {
            notifications.remove()
            return
        }
        do {
            try await notifications.add(Self.request(hour: hour, minute: minute))
            errorMessage = nil
        } catch {
            errorMessage = "Couldn’t schedule the reminder. Please try again."
        }
    }
}

extension Notification.Name {
    static let dailyReminderOpened = Notification.Name("dailyReminderOpened")
}

final class ReminderNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReminderNotificationDelegate()

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.identifier == DailyReminder.identifier,
              response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await MainActor.run {
            NotificationCenter.default.post(name: .dailyReminderOpened, object: nil)
        }
    }
}

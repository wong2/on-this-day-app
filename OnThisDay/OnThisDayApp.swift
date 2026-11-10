import SwiftUI
import UserNotifications

@main
struct OnThisDayApp: App {
    init() {
        UNUserNotificationCenter.current().delegate = ReminderNotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup { LibraryView() }
    }
}

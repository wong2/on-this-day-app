import XCTest
import UserNotifications
@testable import OnThisDay

nonisolated final class DailyReminderTests: XCTestCase {
    @MainActor
    private func makeDefaults() -> UserDefaults {
        let name = "DailyReminderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    @MainActor
    func testDefaultsToTenAMAndRequestsPermissionOnlyWhenEnabled() async throws {
        let client = FakeReminderNotifications()
        let model = DailyReminder(defaults: makeDefaults(), notifications: client)
        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(model.hour, 10)
        XCTAssertEqual(model.minute, 0)
        await model.refresh()
        XCTAssertEqual(client.permissionRequests, 0)
        XCTAssertTrue(client.pending.isEmpty)

        await model.setEnabled(true)
        XCTAssertTrue(model.isEnabled)
        XCTAssertEqual(client.permissionRequests, 1)
        let request = try XCTUnwrap(client.pending[DailyReminder.identifier])
        let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
        XCTAssertTrue(trigger.repeats)
        XCTAssertEqual(trigger.dateComponents.hour, 10)
        XCTAssertEqual(trigger.dateComponents.minute, 0)
        XCTAssertNil(trigger.dateComponents.day)
        XCTAssertNil(trigger.dateComponents.timeZone)
        XCTAssertNotNil(trigger.nextTriggerDate())
        XCTAssertTrue(request.content.attachments.isEmpty)
    }

    @MainActor
    func testTimeChangesReplaceOneReminderAndDisablingPersists() async throws {
        let defaults = makeDefaults()
        let client = FakeReminderNotifications()
        let model = DailyReminder(defaults: defaults, notifications: client)
        await model.setEnabled(true)
        let time = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 14, minute: 35))!
        await model.setTime(time)
        XCTAssertEqual(client.pending.count, 1)
        let trigger = try XCTUnwrap(client.pending[DailyReminder.identifier]?.trigger as? UNCalendarNotificationTrigger)
        XCTAssertEqual(trigger.dateComponents.hour, 14)
        XCTAssertEqual(trigger.dateComponents.minute, 35)
        let restored = DailyReminder(defaults: defaults, notifications: client)
        XCTAssertTrue(restored.isEnabled)
        XCTAssertEqual(restored.hour, 14)
        XCTAssertEqual(restored.minute, 35)
        await restored.setEnabled(false)
        XCTAssertTrue(client.pending.isEmpty)
        XCTAssertFalse(DailyReminder(defaults: defaults, notifications: client).isEnabled)
    }

    @MainActor
    func testDeniedPermissionAndSchedulingFailureDoNotEnableReminder() async {
        let client = FakeReminderNotifications()
        client.status = .denied
        let model = DailyReminder(defaults: makeDefaults(), notifications: client)
        await model.setEnabled(true)
        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(model.authorization, .denied)
        XCTAssertEqual(client.permissionRequests, 0)
        XCTAssertTrue(client.pending.isEmpty)

        client.status = .authorized
        client.shouldFail = true
        await model.setEnabled(true)
        XCTAssertFalse(model.isEnabled)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isUpdating)
        client.shouldFail = false
        await model.setEnabled(true)
        XCTAssertTrue(model.isEnabled)
        XCTAssertNil(model.errorMessage)

        client.shouldFail = true
        await model.setTime(Calendar.current.date(bySettingHour: 15, minute: 45, second: 0, of: model.time)!)
        XCTAssertEqual(model.hour, 10)
        XCTAssertEqual(model.minute, 0)
        XCTAssertNotNil(model.errorMessage)
    }

    @MainActor
    func testRefreshReconcilesSystemPermissionWithoutPrompting() async {
        let client = FakeReminderNotifications()
        let model = DailyReminder(defaults: makeDefaults(), notifications: client)
        await model.setEnabled(true)
        client.status = .denied
        await model.refresh()
        XCTAssertTrue(model.isEnabled)
        XCTAssertTrue(client.pending.isEmpty)
        XCTAssertEqual(model.authorization, .denied)
        client.status = .authorized
        await model.refresh()
        XCTAssertEqual(client.pending.count, 1)
        XCTAssertEqual(client.permissionRequests, 1)
    }
}

@MainActor
private final class FakeReminderNotifications: ReminderNotificationClient {
    var status: UNAuthorizationStatus = .notDetermined
    var permissionRequests = 0
    var pending: [String: UNNotificationRequest] = [:]
    var shouldFail = false

    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAuthorization() async throws -> Bool {
        permissionRequests += 1
        status = .authorized
        return true
    }
    func add(_ request: UNNotificationRequest) async throws {
        if shouldFail { throw CocoaError(.fileWriteUnknown) }
        pending[request.identifier] = request
    }
    func remove() { pending.removeValue(forKey: DailyReminder.identifier) }
}

import UserNotifications
import XCTest
@testable import LunaPremium

@MainActor
final class PremiumHappyHourTests: XCTestCase {
    private func date(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }

    func testBothWeekendDaysAndExactBoundaries() {
        let utc = TimeZone(secondsFromGMT: 0)!
        for day in [24, 25] {
            XCTAssertFalse(PremiumHappyHour.isActive(at: date("2026-10-\(day)T13:59:59Z"), timeZone: utc))
            XCTAssertTrue(PremiumHappyHour.isActive(at: date("2026-10-\(day)T14:00:00Z"), timeZone: utc))
            XCTAssertTrue(PremiumHappyHour.isActive(at: date("2026-10-\(day)T14:59:59Z"), timeZone: utc))
            XCTAssertFalse(PremiumHappyHour.isActive(at: date("2026-10-\(day)T15:00:00Z"), timeZone: utc))
        }
        for day in 26...30 {
            XCTAssertFalse(PremiumHappyHour.isActive(at: date("2026-10-\(day)T14:30:00Z"), timeZone: utc))
        }
    }

    func testUsesLocalDayAndHourIncludingFractionalOffsetsAndDST() {
        XCTAssertTrue(PremiumHappyHour.isActive(at: date("2026-10-24T03:00:00Z"), timeZone: TimeZone(identifier: "Australia/Sydney")!))
        XCTAssertFalse(PremiumHappyHour.isActive(at: date("2026-10-24T03:00:00Z"), timeZone: TimeZone(identifier: "America/Los_Angeles")!))
        XCTAssertTrue(PremiumHappyHour.isActive(at: date("2026-10-24T08:45:00Z"), timeZone: TimeZone(identifier: "Asia/Kathmandu")!))
        XCTAssertTrue(PremiumHappyHour.isActive(at: date("2026-04-05T04:00:00Z"), timeZone: TimeZone(identifier: "Australia/Sydney")!))
    }

    func testPriceRequiresAtLeast25PercentSavingInSameCurrency() {
        func eligible(_ regular: String, _ sale: String, _ currency: String = "USD") -> Bool {
            PremiumHappyHour.isEligiblePrice(regular: Decimal(string: regular)!, discounted: Decimal(string: sale)!, regularCurrency: "USD", discountedCurrency: currency)
        }
        XCTAssertTrue(eligible("2", "1.50"))
        XCTAssertTrue(eligible("2", "1.49"))
        XCTAssertFalse(eligible("2", "1.51"))
        XCTAssertFalse(eligible("2", "1.49", "AUD"))
        XCTAssertFalse(eligible("0", "1"))
        XCTAssertFalse(eligible("2", "0"))
    }

    func testReminderRequestsRepeatOnBothWeekendDaysAtLocal2PM() throws {
        let requests = PremiumHappyHourReminders.requests()
        XCTAssertEqual(requests.count, 2)
        for (request, weekday) in zip(requests, [7, 1]) {
            let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
            XCTAssertTrue(trigger.repeats)
            XCTAssertEqual(trigger.dateComponents.weekday, weekday)
            XCTAssertEqual(trigger.dateComponents.hour, 14)
            XCTAssertEqual(trigger.dateComponents.minute, 0)
            XCTAssertNil(trigger.dateComponents.timeZone)
            XCTAssertFalse(request.content.title.isEmpty)
            XCTAssertFalse(request.content.body.isEmpty)
        }
    }

    func testReminderPermissionOptInAndCancellation() async throws {
        let client = FakeHappyHourNotifications()
        let reminders = PremiumHappyHourReminders(client: client)
        XCTAssertEqual(client.authorizationRequests, 0)
        client.allowed = false
        let denied = try await reminders.enable()
        XCTAssertFalse(denied)
        XCTAssertTrue(client.requests.isEmpty)
        client.allowed = true
        let enabled = try await reminders.enable()
        XCTAssertTrue(enabled)
        let isEnabled = await reminders.isEnabled
        XCTAssertTrue(isEnabled)
        reminders.cancel()
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testPartialSchedulingFailureRemovesBothRequests() async throws {
        let client = FakeHappyHourNotifications()
        client.failSecond = true
        let reminders = PremiumHappyHourReminders(client: client)
        do {
            _ = try await reminders.enable()
            XCTFail("Expected scheduling failure")
        } catch { }
        XCTAssertTrue(client.requests.isEmpty)
    }
}

@MainActor
private final class FakeHappyHourNotifications: HappyHourNotificationClient {
    var allowed = true
    var failSecond = false
    var authorizationRequests = 0
    var requests: [UNNotificationRequest] = []
    func authorizationStatus() async -> UNAuthorizationStatus { allowed ? .authorized : .denied }
    func requestAuthorization() async throws -> Bool { authorizationRequests += 1; return allowed }
    func pendingRequests() async -> [UNNotificationRequest] { requests }
    func add(_ request: UNNotificationRequest) async throws {
        if failSecond && requests.count == 1 { throw CocoaError(.fileWriteUnknown) }
        requests.removeAll { $0.identifier == request.identifier }
        requests.append(request)
    }
    func remove(identifiers: [String]) { requests.removeAll { identifiers.contains($0.identifier) } }
}

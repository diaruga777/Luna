import LunaIntents
import LunaStorage
import UserNotifications
import XCTest

final class TriggerNotificationSchedulerTests: XCTestCase {
    private var suite: String!
    override func setUp() {
        super.setUp()
        suite = "TriggerNotificationSchedulerTests.\(UUID().uuidString)"
        NotificationAuthorizationState.testDefaultsOverride = UserDefaults(suiteName: suite)
    }
    override func tearDown() {
        NotificationAuthorizationState.testDefaultsOverride = nil
        UserDefaults.standard.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testDelayedRequestPreservesAllConfigurableContent() throws {
        let request = try TriggerNotificationScheduler.request(
            delay: 12.5, title: "Luna.workflow.next", subtitle: "Next chunk", body: "{\"index\":2}",
            userInfoJSON: "{\"index\":2,\"ready\":true,\"tags\":[\"a\"],\"nested\":{\"id\":\"abc\"}}",
            identifier: "reading", threadIdentifier: "article", categoryIdentifier: "existing",
            playSound: true, badge: 3, interruptionLevel: .timeSensitive)
        let trigger = try XCTUnwrap(request.trigger as? UNTimeIntervalNotificationTrigger)
        XCTAssertEqual(trigger.timeInterval, 12.5)
        XCTAssertFalse(trigger.repeats)
        XCTAssertEqual(request.identifier, "luna.trigger.reading")
        XCTAssertEqual(request.content.title, "Luna.workflow.next")
        XCTAssertEqual(request.content.subtitle, "Next chunk")
        XCTAssertEqual(request.content.body, "{\"index\":2}")
        XCTAssertEqual(request.content.userInfo["index"] as? Int, 2)
        XCTAssertEqual(request.content.userInfo["ready"] as? Bool, true)
        XCTAssertEqual(request.content.userInfo["nested"] as? [String: String], ["id": "abc"])
        XCTAssertEqual(request.content.threadIdentifier, "article")
        XCTAssertEqual(request.content.categoryIdentifier, "existing")
        XCTAssertNotNil(request.content.sound)
        XCTAssertEqual(request.content.badge, 3)
        XCTAssertEqual(request.content.interruptionLevel, .timeSensitive)
    }

    func testImmediateDefaultsAreQuietAndDoNotChangeBadge() throws {
        let first = try TriggerNotificationScheduler.request(delay: 0, title: "Trigger")
        let second = try TriggerNotificationScheduler.request(delay: 0, title: "Trigger")
        XCTAssertNil(first.trigger)
        XCTAssertNil(first.content.sound)
        XCTAssertNil(first.content.badge)
        XCTAssertTrue(first.content.userInfo.isEmpty)
        XCTAssertEqual(first.content.interruptionLevel, .passive)
        XCTAssertNotEqual(first.identifier, second.identifier)
    }

    func testReturnedIDCanReplacePendingRequestWithoutEscapingNamespace() throws {
        let first = try TriggerNotificationScheduler.request(delay: 10, title: "First", identifier: "luna.change.example")
        let replacement = try TriggerNotificationScheduler.request(delay: 20, title: "Second", identifier: first.identifier)
        XCTAssertEqual(first.identifier, "luna.trigger.luna.change.example")
        XCTAssertEqual(first.identifier, replacement.identifier)
    }

    func testRejectsInvalidInputsIncludingNestedJSONNull() throws {
        for delay in [-1, Double.infinity, -.infinity, .nan] {
            XCTAssertThrowsError(try TriggerNotificationScheduler.request(delay: delay, title: "Trigger"))
        }
        XCTAssertThrowsError(try TriggerNotificationScheduler.request(delay: 1, title: " \n"))
        XCTAssertThrowsError(try TriggerNotificationScheduler.request(delay: 1, title: "Trigger", badge: -1))
        for json in ["oops", "[]", "2", "null", "{\"x\":null}", "{\"x\":[{\"y\":null}]}"] {
            XCTAssertThrowsError(try TriggerNotificationScheduler.request(delay: 1, title: "Trigger", userInfoJSON: json), json)
        }
        XCTAssertNoThrow(try TriggerNotificationScheduler.request(delay: 1, title: "Trigger", userInfoJSON: " \n"))
    }

    func testAuthorizedStatusesScheduleWithoutPermissionPrompt() async throws {
        for status in [UNAuthorizationStatus.authorized, .provisional, .ephemeral] {
            let center = FakeCenter(status: status)
            let request = try TriggerNotificationScheduler.request(delay: 10, title: "Trigger")
            let identifier = try await TriggerNotificationScheduler.schedule(request, center: center)
            XCTAssertEqual(identifier, request.identifier)
            XCTAssertEqual(center.requests.map(\.identifier), [identifier])
            XCTAssertNil(center.authorizationOptions)
        }
    }

    func testUndeterminedRequestsProvisionalPermissionAndUpdatesSharedLatch() async throws {
        let center = FakeCenter(status: .notDetermined)
        let request = try TriggerNotificationScheduler.request(delay: 1, title: "Trigger")
        _ = try await TriggerNotificationScheduler.schedule(request, center: center)
        XCTAssertTrue(center.authorizationOptions?.contains(.provisional) == true)
        XCTAssertTrue(NotificationAuthorizationState.hasEverBeenRequested)
        XCTAssertEqual(center.requests.count, 1)
    }

    func testDeniedPermissionNeverSchedules() async throws {
        for status in [UNAuthorizationStatus.denied, .notDetermined] {
            let center = FakeCenter(status: status)
            center.grantsAuthorization = false
            let request = try TriggerNotificationScheduler.request(delay: 1, title: "Trigger")
            do {
                _ = try await TriggerNotificationScheduler.schedule(request, center: center)
                XCTFail("Expected permission error")
            } catch {
                XCTAssertTrue(error is TriggerNotificationScheduler.SchedulingError)
            }
            XCTAssertTrue(center.requests.isEmpty)
        }
    }

    func testSchedulingFailureReachesCaller() async throws {
        let center = FakeCenter(status: .authorized)
        center.addError = TestError.failed
        let request = try TriggerNotificationScheduler.request(delay: 1, title: "Trigger")
        do {
            _ = try await TriggerNotificationScheduler.schedule(request, center: center)
            XCTFail("Expected add failure")
        } catch {
            XCTAssertTrue(error is TestError)
        }
    }
}

private enum TestError: Error { case failed }
private final class FakeCenter: TriggerNotificationCenter {
    var status: UNAuthorizationStatus
    var grantsAuthorization = true
    var authorizationOptions: UNAuthorizationOptions?
    var requests: [UNNotificationRequest] = []
    var addError: Error?
    init(status: UNAuthorizationStatus) { self.status = status }
    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        authorizationOptions = options
        return grantsAuthorization
    }
    func add(_ request: UNNotificationRequest) async throws {
        if let addError { throw addError }
        requests.append(request)
    }
}

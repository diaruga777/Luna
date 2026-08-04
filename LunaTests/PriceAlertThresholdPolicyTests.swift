//
//  PriceAlertThresholdPolicyTests.swift
//  LunaTests
//
//  What a newly tracked product's alert threshold is, and the notification
//  permission latch that decides it.
//

import LunaModels
import XCTest
@testable import LunaStorage

final class PriceAlertThresholdPolicyTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PriceAlertThresholdPolicyTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        NotificationAuthorizationState.testDefaultsOverride = defaults
    }

    override func tearDown() {
        NotificationAuthorizationState.testDefaultsOverride = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - The policy (pure)

    func testNewTrackerHasNoThresholdUntilNotificationsHaveBeenAsked() {
        XCTAssertNil(
            PriceAlertThresholdPolicy.initialThresholdFraction(notificationsEverRequested: false),
            "nothing can notify yet, so nothing is promised")
    }

    func testNewTrackerGetsTheDefaultThresholdOnceNotificationsHaveBeenAsked() {
        XCTAssertEqual(
            PriceAlertThresholdPolicy.initialThresholdFraction(notificationsEverRequested: true),
            PriceTracker.defaultAlertThresholdFraction,
            "granted OR denied — the question has been answered, so trackers alert as before")
    }

    // MARK: - The latch

    func testLatchStartsClearAndDrivesTheUnsetThreshold() {
        XCTAssertFalse(NotificationAuthorizationState.hasEverBeenRequested)
        XCTAssertNil(PriceAlertThresholdPolicy.initialThresholdFraction)
    }

    func testMarkingRequestedIsStickyAndSeedsTheDefaultThreshold() {
        NotificationAuthorizationState.markRequested()
        XCTAssertTrue(NotificationAuthorizationState.hasEverBeenRequested)
        XCTAssertEqual(
            PriceAlertThresholdPolicy.initialThresholdFraction,
            PriceTracker.defaultAlertThresholdFraction)

        // A denied (or later revoked) permission is still an answered question.
        NotificationAuthorizationState.recordSystemStatus(determined: false)
        XCTAssertTrue(
            NotificationAuthorizationState.hasEverBeenRequested,
            "the latch never un-latches")
    }

    func testUndeterminedSystemStatusDoesNotLatch() {
        NotificationAuthorizationState.recordSystemStatus(determined: false)
        XCTAssertFalse(NotificationAuthorizationState.hasEverBeenRequested)

        NotificationAuthorizationState.recordSystemStatus(determined: true)
        XCTAssertTrue(NotificationAuthorizationState.hasEverBeenRequested)
    }

    func testResetClearsTheLatch() {
        NotificationAuthorizationState.markRequested()
        NotificationAuthorizationState.reset()
        XCTAssertFalse(NotificationAuthorizationState.hasEverBeenRequested)
        XCTAssertNil(PriceAlertThresholdPolicy.initialThresholdFraction)
    }
}

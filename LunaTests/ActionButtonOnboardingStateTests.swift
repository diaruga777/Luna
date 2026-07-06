//
//  ActionButtonOnboardingStateTests.swift
//  LunaTests
//

import LunaStorage
import XCTest

final class ActionButtonOnboardingStateTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ActionButtonOnboardingStore!

    override func setUp() {
        super.setUp()
        suiteName = "ActionButtonOnboardingStateTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = ActionButtonOnboardingStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Basic state get/set

    func testDefaultStateIsNotStarted() {
        XCTAssertEqual(store.state(forSurface: "reader"), .notStarted)
    }

    func testSetStateRoundTrips() {
        store.setState(.installTapped, forSurface: "reader")
        XCTAssertEqual(store.state(forSurface: "reader"), .installTapped)
    }

    func testPerSurfaceIsolation() {
        store.setState(.installTapped, forSurface: "reader")
        XCTAssertEqual(store.state(forSurface: "reader"), .installTapped)
        XCTAssertEqual(store.state(forSurface: "downloader"), .notStarted)
        XCTAssertEqual(store.state(forSurface: "pricetracker"), .notStarted)
    }

    // MARK: - Notification posting

    func testSetStatePostsNotificationOnlyWhenValueChanges() {
        let expectation = expectation(forNotification: ActionButtonOnboardingStore.stateDidChangeNotification,
                                       object: "reader")
        store.setState(.installTapped, forSurface: "reader")
        wait(for: [expectation], timeout: 1)

        // Setting the same value again must NOT post again.
        var postedAgain = false
        let observer = NotificationCenter.default.addObserver(
            forName: ActionButtonOnboardingStore.stateDidChangeNotification, object: nil, queue: nil
        ) { _ in postedAgain = true }
        store.setState(.installTapped, forSurface: "reader")
        NotificationCenter.default.removeObserver(observer)
        XCTAssertFalse(postedAgain)
    }

    // MARK: - beginInstallStep

    func testBeginInstallStepSetsInstallTappedFromAnyState() {
        store.beginInstallStep(forSurface: "reader")
        XCTAssertEqual(store.state(forSurface: "reader"), .installTapped)

        store.setState(.done, forSurface: "reader")
        store.beginInstallStep(forSurface: "reader") // re-arms on onboarding replay
        XCTAssertEqual(store.state(forSurface: "reader"), .installTapped)
    }

    // MARK: - handleAppBackgrounded

    func testBackgroundOnlyAdvancesFromInstallTapped() {
        store.setState(.installTapped, forSurface: "reader")
        store.handleAppBackgrounded(forSurface: "reader")
        XCTAssertEqual(store.state(forSurface: "reader"), .awaitingShortcutRun)
    }

    func testBackgroundIgnoredFromEveryOtherState() {
        let untouchedStates: [ActionButtonOnboardingState] = [
            .notStarted, .awaitingShortcutRun, .actionButtonSetup, .awaitingActionButton, .done
        ]
        for state in untouchedStates {
            store.setState(state, forSurface: "reader")
            store.handleAppBackgrounded(forSurface: "reader")
            XCTAssertEqual(store.state(forSurface: "reader"), state,
                            "background should not alter state \(state)")
        }
    }

    // MARK: - handleAppForegrounded (one-shot skip)

    func testForegroundSkipAdvancesFromAwaitingShortcutRunOnce() {
        store.setState(.awaitingShortcutRun, forSurface: "reader")
        store.handleAppForegrounded(forSurface: "reader")
        XCTAssertEqual(store.state(forSurface: "reader"), .actionButtonSetup)

        // A second foreground must NOT fire again — it's a one-shot skip, and
        // actionButtonSetup isn't itself a trigger state.
        store.handleAppForegrounded(forSurface: "reader")
        XCTAssertEqual(store.state(forSurface: "reader"), .actionButtonSetup)
    }

    func testForegroundNeverFiresFromAwaitingActionButton() {
        store.setState(.awaitingActionButton, forSurface: "reader")
        store.handleAppForegrounded(forSurface: "reader")
        XCTAssertEqual(store.state(forSurface: "reader"), .awaitingActionButton)
    }

    func testForegroundIgnoredFromEveryOtherState() {
        let untouchedStates: [ActionButtonOnboardingState] = [
            .notStarted, .installTapped, .actionButtonSetup, .awaitingActionButton, .done
        ]
        for state in untouchedStates {
            store.setState(state, forSurface: "reader")
            store.handleAppForegrounded(forSurface: "reader")
            XCTAssertEqual(store.state(forSurface: "reader"), state,
                            "foreground should not alter state \(state)")
        }
    }

    // MARK: - markSettingsDeeplinkTapped

    func testMarkSettingsDeeplinkTappedAdvancesFromActionButtonSetup() {
        store.setState(.actionButtonSetup, forSurface: "reader")
        store.markSettingsDeeplinkTapped(forSurface: "reader")
        XCTAssertEqual(store.state(forSurface: "reader"), .awaitingActionButton)
    }

    func testMarkSettingsDeeplinkTappedIgnoredFromOtherStates() {
        store.setState(.installTapped, forSurface: "reader")
        store.markSettingsDeeplinkTapped(forSurface: "reader")
        XCTAssertEqual(store.state(forSurface: "reader"), .installTapped)
    }

    // MARK: - handleSaveIntentInvoked interception matrix

    func testAwaitingShortcutRunPlusShortcutsAppReturnsToken() {
        store.setState(.awaitingShortcutRun, forSurface: "reader")
        let result = store.handleSaveIntentInvoked(
            appName: "Shortcuts", isCurrentAppLuna: false, forSurface: "reader")
        XCTAssertEqual(result, .returnOpenLunaToken)
        XCTAssertEqual(store.state(forSurface: "reader"), .actionButtonSetup)
    }

    func testAwaitingShortcutRunPlusShortcutsAppIsCaseInsensitive() {
        store.setState(.awaitingShortcutRun, forSurface: "reader")
        let result = store.handleSaveIntentInvoked(
            appName: "shortcuts", isCurrentAppLuna: false, forSurface: "reader")
        XCTAssertEqual(result, .returnOpenLunaToken)
    }

    func testAwaitingShortcutRunPlusOtherAppDoesNothing() {
        store.setState(.awaitingShortcutRun, forSurface: "reader")
        let result = store.handleSaveIntentInvoked(
            appName: "Safari", isCurrentAppLuna: false, forSurface: "reader")
        XCTAssertEqual(result, .none)
        XCTAssertEqual(store.state(forSurface: "reader"), .awaitingShortcutRun)
    }

    func testActionButtonSetupPlusAnyAppReturnsTokenAndCompletes() {
        store.setState(.actionButtonSetup, forSurface: "reader")
        let result = store.handleSaveIntentInvoked(
            appName: "Safari", isCurrentAppLuna: false, forSurface: "reader")
        XCTAssertEqual(result, .returnOpenLunaToken)
        XCTAssertEqual(store.state(forSurface: "reader"), .done)
    }

    func testAwaitingActionButtonPlusAnyAppReturnsTokenAndCompletes() {
        store.setState(.awaitingActionButton, forSurface: "reader")
        let result = store.handleSaveIntentInvoked(
            appName: "YouTube", isCurrentAppLuna: false, forSurface: "reader")
        XCTAssertEqual(result, .returnOpenLunaToken)
        XCTAssertEqual(store.state(forSurface: "reader"), .done)
    }

    func testActionButtonSetupPlusLunaFrontmostReturnsEmptyAndCompletes() {
        store.setState(.actionButtonSetup, forSurface: "reader")
        let result = store.handleSaveIntentInvoked(
            appName: "Luna", isCurrentAppLuna: true, forSurface: "reader")
        XCTAssertEqual(result, .returnEmpty)
        XCTAssertEqual(store.state(forSurface: "reader"), .done)
    }

    func testAwaitingActionButtonPlusLunaFrontmostReturnsEmptyAndCompletes() {
        store.setState(.awaitingActionButton, forSurface: "reader")
        let result = store.handleSaveIntentInvoked(
            appName: "Luna", isCurrentAppLuna: true, forSurface: "reader")
        XCTAssertEqual(result, .returnEmpty)
        XCTAssertEqual(store.state(forSurface: "reader"), .done)
    }

    func testNotStartedAndDoneDoNothing() {
        for state: ActionButtonOnboardingState in [.notStarted, .done] {
            store.setState(state, forSurface: "reader")
            let result = store.handleSaveIntentInvoked(
                appName: "YouTube", isCurrentAppLuna: false, forSurface: "reader")
            XCTAssertEqual(result, .none)
            XCTAssertEqual(store.state(forSurface: "reader"), state)
        }
    }

    func testInstallTappedDoesNothing() {
        store.setState(.installTapped, forSurface: "reader")
        let result = store.handleSaveIntentInvoked(
            appName: "Shortcuts", isCurrentAppLuna: false, forSurface: "reader")
        XCTAssertEqual(result, .none)
        XCTAssertEqual(store.state(forSurface: "reader"), .installTapped)
    }

    // MARK: - Token constant

    func testOpenLunaTokenIsStable() {
        // The bundled Shortcut branches on this exact literal.
        XCTAssertEqual(ActionButtonOnboardingStore.openLunaToken, "open-luna")
    }
}

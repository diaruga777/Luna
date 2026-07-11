//
//  ActionButtonOnboardingStateTests.swift
//  LunaTests
//
//  Focused coverage of `ActionButtonOnboardingStore.handleProvideContextInvoked`'s
//  three `ProvideContextInterception` outcomes and the state transitions they
//  drive — exercised over an injected test-local `UserDefaults` suite rather
//  than the real App-Group-backed singleton.
//

import LunaStorage
import XCTest

final class ActionButtonOnboardingStateTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ActionButtonOnboardingStore!
    private let surface = "reader"

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

    // MARK: - .none (no interception)

    func testNotStartedYieldsNoneAndNoTransition() {
        XCTAssertEqual(
            store.handleProvideContextInvoked(appName: "Safari", isCurrentAppLuna: false, forSurface: surface),
            .none)
        XCTAssertEqual(store.state(forSurface: surface), .notStarted)
    }

    func testInstallTappedYieldsNoneAndNoTransition() {
        store.setState(.installTapped, forSurface: surface)
        XCTAssertEqual(
            store.handleProvideContextInvoked(appName: "Safari", isCurrentAppLuna: false, forSurface: surface),
            .none)
        XCTAssertEqual(store.state(forSurface: surface), .installTapped)
    }

    func testDoneYieldsNoneAndNoTransition() {
        store.setState(.done, forSurface: surface)
        XCTAssertEqual(
            store.handleProvideContextInvoked(appName: "Safari", isCurrentAppLuna: false, forSurface: surface),
            .none)
        XCTAssertEqual(store.state(forSurface: surface), .done)
    }

    func testAwaitingShortcutRunFromNonShortcutsAppYieldsNoneAndNoTransition() {
        store.setState(.awaitingShortcutRun, forSurface: surface)
        XCTAssertEqual(
            store.handleProvideContextInvoked(appName: "Safari", isCurrentAppLuna: false, forSurface: surface),
            .none)
        XCTAssertEqual(store.state(forSurface: surface), .awaitingShortcutRun)
    }

    // MARK: - .foregroundThenUnsupported

    func testAwaitingShortcutRunFromShortcutsAdvancesAndForegrounds() {
        store.setState(.awaitingShortcutRun, forSurface: surface)
        XCTAssertEqual(
            store.handleProvideContextInvoked(appName: "Shortcuts", isCurrentAppLuna: false, forSurface: surface),
            .foregroundThenUnsupported)
        XCTAssertEqual(store.state(forSurface: surface), .actionButtonSetup)
    }

    func testAwaitingShortcutRunFromShortcutsIsCaseInsensitive() {
        store.setState(.awaitingShortcutRun, forSurface: surface)
        XCTAssertEqual(
            store.handleProvideContextInvoked(appName: "shortCUTS", isCurrentAppLuna: false, forSurface: surface),
            .foregroundThenUnsupported)
    }

    func testActionButtonSetupWithLunaNotFrontmostForegroundsAndAdvancesToDone() {
        store.setState(.actionButtonSetup, forSurface: surface)
        XCTAssertEqual(
            store.handleProvideContextInvoked(appName: "TikTok", isCurrentAppLuna: false, forSurface: surface),
            .foregroundThenUnsupported)
        XCTAssertEqual(store.state(forSurface: surface), .done)
    }

    func testAwaitingActionButtonWithLunaNotFrontmostForegroundsAndAdvancesToDone() {
        store.setState(.awaitingActionButton, forSurface: surface)
        XCTAssertEqual(
            store.handleProvideContextInvoked(appName: "TikTok", isCurrentAppLuna: false, forSurface: surface),
            .foregroundThenUnsupported)
        XCTAssertEqual(store.state(forSurface: surface), .done)
    }

    // MARK: - .unsupported (no foreground needed — Luna already frontmost)

    func testActionButtonSetupWithLunaFrontmostReportsUnsupportedAndAdvancesToDone() {
        store.setState(.actionButtonSetup, forSurface: surface)
        XCTAssertEqual(
            store.handleProvideContextInvoked(appName: "Luna", isCurrentAppLuna: true, forSurface: surface),
            .unsupported)
        XCTAssertEqual(store.state(forSurface: surface), .done)
    }

    func testAwaitingActionButtonWithLunaFrontmostReportsUnsupportedAndAdvancesToDone() {
        store.setState(.awaitingActionButton, forSurface: surface)
        XCTAssertEqual(
            store.handleProvideContextInvoked(appName: "Luna", isCurrentAppLuna: true, forSurface: surface),
            .unsupported)
        XCTAssertEqual(store.state(forSurface: surface), .done)
    }

    // MARK: - Per-surface isolation

    func testInterceptionIsPerSurface() {
        store.setState(.awaitingShortcutRun, forSurface: "reader")
        XCTAssertEqual(
            store.handleProvideContextInvoked(appName: "Safari", isCurrentAppLuna: false, forSurface: "downloader"),
            .none)
        XCTAssertEqual(store.state(forSurface: "reader"), .awaitingShortcutRun)
        XCTAssertEqual(store.state(forSurface: "downloader"), .notStarted)
    }
}

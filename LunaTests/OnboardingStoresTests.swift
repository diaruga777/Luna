//
//  OnboardingStoresTests.swift
//  LunaTests
//
//  `OnboardingStores.ephemeral()` backs Settings → "Replay Onboarding": these
//  tests exercise its email/Safari isolation guarantees, Action Button
//  reset/restore bridge, and Safari enablement read-through rule via the
//  testable designated init, injecting stores over test-local `UserDefaults`
//  suites rather than the true App-Group-backed singletons.
//

import LunaMailAccount
import LunaStorage
import XCTest
@testable import Luna

final class OnboardingStoresTests: XCTestCase {

    private var scratchSuiteName: String!
    private var scratchDefaults: UserDefaults!
    private var realSuiteName: String!
    private var realDefaults: UserDefaults!
    private var actionSuiteName: String!
    private var actionDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        scratchSuiteName = "OnboardingStoresTests.scratch.\(UUID().uuidString)"
        scratchDefaults = UserDefaults(suiteName: scratchSuiteName)
        realSuiteName = "OnboardingStoresTests.real.\(UUID().uuidString)"
        realDefaults = UserDefaults(suiteName: realSuiteName)
        actionSuiteName = "OnboardingStoresTests.action.\(UUID().uuidString)"
        actionDefaults = UserDefaults(suiteName: actionSuiteName)
    }

    override func tearDown() {
        scratchDefaults.removePersistentDomain(forName: scratchSuiteName)
        realDefaults.removePersistentDomain(forName: realSuiteName)
        actionDefaults.removePersistentDomain(forName: actionSuiteName)
        scratchDefaults = nil
        realDefaults = nil
        actionDefaults = nil
        scratchSuiteName = nil
        realSuiteName = nil
        actionSuiteName = nil
        super.tearDown()
    }

    /// Builds an ephemeral-shaped `OnboardingStores`: scratch stores over
    /// `scratchDefaults`, with `realDefaults` standing in for the real,
    /// App-Group-backed Safari store used for the read-through baseline.
    private func makeEphemeralStores(
        baselineSafariEnabled: Bool = false,
        actionButtonRestoreState: ActionButtonOnboardingState? = nil
    ) -> (stores: OnboardingStores, realSafari: SafariExtensionStatusStore, actionButton: ActionButtonOnboardingStore) {
        let realSafari = SafariExtensionStatusStore(defaults: realDefaults)
        if baselineSafariEnabled {
            realSafari.recordEnabled(forSurface: "reader")
        }
        let actionButton = ActionButtonOnboardingStore(defaults: actionDefaults)
        if let actionButtonRestoreState {
            actionButton.setState(actionButtonRestoreState, forSurface: "reader")
        }
        let actionButtonRestoreStates = actionButtonRestoreState.map { ["reader": $0] } ?? [:]
        if actionButtonRestoreState != nil {
            actionButton.setState(.notStarted, forSurface: "reader")
        }
        let stores = OnboardingStores(
            emailAccountStore: EmailAccountStore(
                defaults: scratchDefaults, credentialStorage: InMemoryCredentialStorage()),
            safariStatusStore: SafariExtensionStatusStore(defaults: scratchDefaults),
            actionButtonStore: actionButton,
            realSafariStatusStore: realSafari,
            baselineSafariEnabled: ["reader": baselineSafariEnabled],
            actionButtonRestoreStates: actionButtonRestoreStates,
            scratchSuiteName: scratchSuiteName)
        return (stores, realSafari, actionButton)
    }

    // MARK: - Isolation: replay-only email/Safari writes never touch "real"

    func testEphemeralWritesLeaveRealSuiteUntouched() {
        let (stores, _, _) = makeEphemeralStores()

        stores.setSafariTakeoverPending(true, forSurface: "reader")
        stores.setActionButtonState(.installTapped, forSurface: "reader")
        stores.beginActionButtonInstallStep(forSurface: "reader")
        stores.emailAccountStore.save(
            EmailAccount(providerID: .gmail, address: "a@gmail.com"),
            credential: .appPassword("secret"))

        // Fresh stores rebuilt directly over the "real" suite see none of it.
        let realEmailStore = EmailAccountStore(
            defaults: realDefaults, credentialStorage: InMemoryCredentialStorage())
        XCTAssertFalse(realEmailStore.isConfigured)
        XCTAssertNil(realEmailStore.account)

        let realSafariCheck = SafariExtensionStatusStore(defaults: realDefaults)
        XCTAssertFalse(realSafariCheck.isTakeoverPending(forSurface: "reader"))

        let unrelatedActionButtonCheck = ActionButtonOnboardingStore(defaults: realDefaults)
        XCTAssertEqual(unrelatedActionButtonCheck.state(forSurface: "reader"), .notStarted)
    }

    func testEphemeralAccessorsReadBackTheirOwnScratchWrites() {
        let (stores, _, _) = makeEphemeralStores()
        stores.setSafariTakeoverPending(true, forSurface: "reader")
        stores.setActionButtonState(.actionButtonSetup, forSurface: "reader")

        XCTAssertEqual(stores.actionButtonState(forSurface: "reader"), .actionButtonSetup)
        // Round trip through a second handle onto the same scratch suite.
        XCTAssertTrue(SafariExtensionStatusStore(defaults: scratchDefaults).isTakeoverPending(forSurface: "reader"))
    }

    func testTearDownRemovesTheScratchDomain() {
        let (stores, _, _) = makeEphemeralStores()
        stores.setSafariTakeoverPending(true, forSurface: "reader")
        stores.tearDown()

        let reloaded = SafariExtensionStatusStore(defaults: UserDefaults(suiteName: scratchSuiteName))
        XCTAssertFalse(reloaded.isTakeoverPending(forSurface: "reader"))
    }

    func testTearDownIsANoOpForRealShapedStores() {
        let shared = SafariExtensionStatusStore(defaults: realDefaults)
        let stores = OnboardingStores(
            emailAccountStore: EmailAccountStore(
                defaults: realDefaults, credentialStorage: InMemoryCredentialStorage()),
            safariStatusStore: shared,
            actionButtonStore: ActionButtonOnboardingStore(defaults: realDefaults),
            realSafariStatusStore: shared,
            baselineSafariEnabled: [:],
            actionButtonRestoreStates: [:],
            scratchSuiteName: nil)
        shared.setTakeoverPending(true, forSurface: "reader")
        stores.tearDown() // must not remove the real suite
        XCTAssertTrue(shared.isTakeoverPending(forSurface: "reader"))
    }

    // MARK: - Safari enablement read-through rule

    func testBaselineEnabledAndRealStillEnabledReportsFalse() {
        let (stores, _, _) = makeEphemeralStores(baselineSafariEnabled: true)
        XCTAssertFalse(stores.isSafariExtensionEnabled(forSurface: "reader"))
        XCTAssertTrue(stores.shouldUseActionButtonFlowAfterSafari(forSurface: "reader"))
    }

    func testBaselineDisabledAndRealFlipsTrueReportsTrue() {
        let (stores, realSafari, _) = makeEphemeralStores(baselineSafariEnabled: false)
        XCTAssertFalse(stores.isSafariExtensionEnabled(forSurface: "reader"))
        XCTAssertFalse(stores.shouldUseActionButtonFlowAfterSafari(forSurface: "reader"))

        realSafari.recordEnabled(forSurface: "reader")
        XCTAssertTrue(stores.isSafariExtensionEnabled(forSurface: "reader"))
        XCTAssertTrue(stores.shouldUseActionButtonFlowAfterSafari(forSurface: "reader"))
    }

    func testScratchWriteTrueReportsTrueRegardlessOfBaseline() {
        let (stores, _, _) = makeEphemeralStores(baselineSafariEnabled: false)
        XCTAssertFalse(stores.isSafariExtensionEnabled(forSurface: "reader"))

        SafariExtensionStatusStore(defaults: scratchDefaults).recordEnabled(forSurface: "reader")
        XCTAssertTrue(stores.isSafariExtensionEnabled(forSurface: "reader"))
        XCTAssertTrue(stores.shouldUseActionButtonFlowAfterSafari(forSurface: "reader"))
    }

    func testReadThroughIsPerSurface() {
        let (stores, realSafari, _) = makeEphemeralStores(baselineSafariEnabled: false)
        realSafari.recordEnabled(forSurface: "downloader")
        // Baseline dictionary only covers "reader" — a surface with no baseline
        // entry defaults to `false`, so this "downloader" real-enable also reads
        // through as newly-enabled for downloader specifically, but must not
        // leak into "reader".
        XCTAssertFalse(stores.isSafariExtensionEnabled(forSurface: "reader"))
    }

    func testRealShapedStoresPassThroughDirectlyIgnoringBaseline() {
        let shared = SafariExtensionStatusStore(defaults: realDefaults)
        let stores = OnboardingStores(
            emailAccountStore: EmailAccountStore(
                defaults: realDefaults, credentialStorage: InMemoryCredentialStorage()),
            safariStatusStore: shared,
            actionButtonStore: ActionButtonOnboardingStore(defaults: realDefaults),
            realSafariStatusStore: shared,
            baselineSafariEnabled: [:],
            actionButtonRestoreStates: [:],
            scratchSuiteName: nil)

        XCTAssertFalse(stores.isSafariExtensionEnabled(forSurface: "reader"))
        XCTAssertFalse(stores.shouldUseActionButtonFlowAfterSafari(forSurface: "reader"))
        shared.recordEnabled(forSurface: "reader")
        XCTAssertTrue(stores.isSafariExtensionEnabled(forSurface: "reader"))
        XCTAssertTrue(stores.shouldUseActionButtonFlowAfterSafari(forSurface: "reader"))
    }

    // MARK: - Action Button replay reset/restore

    func testEphemeralActionButtonUsesInjectedStoreAndRestoresPreviousStateOnTearDown() {
        let (stores, _, actionButton) = makeEphemeralStores(actionButtonRestoreState: .done)
        XCTAssertEqual(actionButton.state(forSurface: "reader"), .notStarted)

        stores.beginActionButtonInstallStep(forSurface: "reader")
        XCTAssertEqual(actionButton.state(forSurface: "reader"), .installTapped)

        stores.setActionButtonState(.actionButtonSetup, forSurface: "reader")
        XCTAssertEqual(actionButton.state(forSurface: "reader"), .actionButtonSetup)

        stores.tearDown()
        XCTAssertEqual(actionButton.state(forSurface: "reader"), .done)
    }
}

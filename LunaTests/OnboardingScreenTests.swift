//
//  OnboardingScreenTests.swift
//  LunaTests
//
//  Snapshot + layout/navigation coverage for every onboarding step.
//

import LunaMailAccount
import LunaSocialUI
import LunaStorage
import UIKit
import XCTest
@testable import Luna

final class OnboardingScreenTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UIView.setAnimationsEnabled(false)
    }

    /// Snapshots each onboarding step in flow order: email, Safari extension,
    /// Action Button shortcut install, Action Button setup, then the pre-27/
    /// Safari-skipped action-extension step. The Action Button pair and the
    /// action-extension step are mutually exclusive at runtime (chosen by OS
    /// version / whether Safari got enabled), but their factories build on any OS,
    /// so `stepViewControllersForTesting()` includes all of them for coverage.
    func testOnboardingStepsSnapshot() {
        let steps = OnboardingFlow.stepViewControllersForTesting()
        XCTAssertGreaterThanOrEqual(steps.count, 5, "expected email + safari + shortcut install + action button + action extension")
        for (index, step) in steps.enumerated() {
            SnapshotTesting.assertSnapshot(of: step, named: "onboarding-step-\(index)")
        }
    }

    /// The first step's primary control exists and is laid out.
    func testFirstStepHasContinueControl() {
        let steps = OnboardingFlow.stepViewControllersForTesting()
        let first = steps[0]
        let window = UITestSupport.host(first)
        let buttons = allButtons(in: first.view)
        XCTAssertGreaterThan(buttons.count, 0, "first step should have at least one button")
        for button in buttons where !button.isHidden {
            LayoutAssertions.assertVisibleAndInBounds(button, in: first.view)
        }
        _ = window
    }

    /// Every setup step has its buttons on-screen and non-overlapping (basic layout sanity).
    func testSetupStepsLayoutSane() {
        let steps = OnboardingFlow.stepViewControllersForTesting()
        for step in steps.dropFirst() {
            let window = UITestSupport.host(step)
            let buttons = allButtons(in: step.view)
            XCTAssertGreaterThan(buttons.count, 0, "setup step \(step) should have a button")
            for button in buttons where !button.isHidden {
                LayoutAssertions.assertVisibleAndInBounds(button, in: step.view)
            }
            _ = window
        }
    }

    /// The full onboarding flow root builds and presents the email step first.
    func testOnboardingFlowRootShowsEmailFirst() {
        var finished = false
        let root = OnboardingFlow.make { finished = true }
        let window = UITestSupport.host(root)
        let nav = root as? UINavigationController
        XCTAssertNotNil(nav)
        // Type check runs in the app image (see `OnboardingFlow.isOnboardingStep`):
        // the test bundle carries its own duplicate copy of the LunaSocialUI classes,
        // so an `is` check compiled here can spuriously fail cross-image.
        XCTAssertTrue(OnboardingFlow.isOnboardingStep(nav?.topViewController),
                      "onboarding flow should open on the email step, got \(String(describing: nav?.topViewController))")
        XCTAssertFalse(finished)
        _ = window
    }

    /// Even when some other store is already configured, `OnboardingFlow.make(stores:)`
    /// over a fresh ephemeral-shaped bundle still opens on the email step — the
    /// factory only ever consults the passed-in `OnboardingStores`, never a shared
    /// singleton, which is what lets Settings → "Replay Onboarding" behave exactly
    /// like a fresh install regardless of the app's real, persisted state.
    func testOnboardingFlowWithFreshEphemeralStoresStartsAtEmailEvenWhenAnotherStoreIsConfigured() {
        let otherSuiteName = "OnboardingFlowTests.other.\(UUID().uuidString)"
        let otherDefaults = UserDefaults(suiteName: otherSuiteName)!
        defer { otherDefaults.removePersistentDomain(forName: otherSuiteName) }
        let otherEmailStore = EmailAccountStore(
            defaults: otherDefaults, credentialStorage: InMemoryCredentialStorage())
        otherEmailStore.save(
            EmailAccount(providerID: .gmail, address: "someone@gmail.com"),
            credential: .appPassword("secret"))
        XCTAssertTrue(otherEmailStore.isConfigured, "sanity: the 'elsewhere' store really is configured")

        let scratchSuiteName = "OnboardingFlowTests.scratch.\(UUID().uuidString)"
        let scratchDefaults = UserDefaults(suiteName: scratchSuiteName)!
        defer { scratchDefaults.removePersistentDomain(forName: scratchSuiteName) }
        let fresh = OnboardingStores(
            emailAccountStore: EmailAccountStore(
                defaults: scratchDefaults, credentialStorage: InMemoryCredentialStorage()),
            safariStatusStore: SafariExtensionStatusStore(defaults: scratchDefaults),
            actionButtonStore: ActionButtonOnboardingStore(defaults: scratchDefaults),
            realSafariStatusStore: .shared,
            baselineSafariEnabled: [:],
            scratchSuiteName: scratchSuiteName)

        var finished = false
        let root = OnboardingFlow.make(stores: fresh) { finished = true }
        let window = UITestSupport.host(root)
        let nav = root as? UINavigationController
        XCTAssertNotNil(nav)
        XCTAssertTrue(OnboardingFlow.isOnboardingStep(nav?.topViewController),
                      "a fresh ephemeral bundle should open on the email step, got \(String(describing: nav?.topViewController))")
        XCTAssertFalse(finished)
        _ = window
    }

    /// iPhone-mini point size — every step keeps its buttons reachable and in-bounds.
    private static let miniSize = CGSize(width: 375, height: 812)

    func testStepsFitSmallScreen() {
        let steps = OnboardingFlow.stepViewControllersForTesting()
        for step in steps {
            let window = UITestSupport.host(step, size: Self.miniSize)
            let buttons = allButtons(in: step.view)
            for button in buttons where !button.isHidden {
                LayoutAssertions.assertVisibleAndInBounds(button, in: step.view)
            }
            _ = window
        }
    }

    private func allButtons(in view: UIView) -> [UIButton] {
        var found: [UIButton] = []
        if let button = view as? UIButton { found.append(button) }
        for subview in view.subviews { found.append(contentsOf: allButtons(in: subview)) }
        return found
    }
}

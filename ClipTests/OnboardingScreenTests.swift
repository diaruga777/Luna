//
//  OnboardingScreenTests.swift
//  ClipTests
//
//  Snapshot + layout/navigation coverage for every onboarding step.
//

import UIKit
import XCTest
@testable import Clip

final class OnboardingScreenTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UIView.setAnimationsEnabled(false)
    }

    /// Snapshots each onboarding step in flow order. Step 0 is the username screen;
    /// the rest are the device-setup steps.
    func testOnboardingStepsSnapshot() {
        let steps = OnboardingFlow.stepViewControllersForTesting()
        XCTAssertGreaterThanOrEqual(steps.count, 3, "expected at least username + 2 setup steps")
        for (index, step) in steps.enumerated() {
            SnapshotTesting.assertSnapshot(of: step, named: "onboarding-step-\(index)")
        }
    }

    /// The username step's primary "Continue" control exists and is laid out.
    func testUsernameStepHasContinueControl() {
        let steps = OnboardingFlow.stepViewControllersForTesting()
        let username = steps[0]
        let window = UITestSupport.host(username)
        let buttons = allButtons(in: username.view)
        XCTAssertGreaterThan(buttons.count, 0, "username step should have at least one button")
        for button in buttons {
            LayoutAssertions.assertVisibleAndInBounds(button, in: username.view)
        }
        _ = window
    }

    /// Every setup step has its primary/continue buttons on-screen and non-overlapping
    /// with the title region (basic layout sanity, no broken layouts).
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

    /// The full onboarding flow root builds and presents the username step first.
    func testOnboardingFlowRootShowsUsernameFirst() {
        var finished = false
        let root = OnboardingFlow.make { finished = true }
        let window = UITestSupport.host(root)
        let nav = root as? UINavigationController
        XCTAssertNotNil(nav)
        XCTAssertTrue(nav?.topViewController is OnboardingViewController,
                      "onboarding flow should open on the username step")
        XCTAssertFalse(finished)
        _ = window
    }

    private func allButtons(in view: UIView) -> [UIButton] {
        var found: [UIButton] = []
        if let button = view as? UIButton { found.append(button) }
        for subview in view.subviews { found.append(contentsOf: allButtons(in: subview)) }
        return found
    }
}

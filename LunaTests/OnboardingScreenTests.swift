//
//  OnboardingScreenTests.swift
//  LunaTests
//
//  Snapshot + layout/navigation coverage for every onboarding step.
//

import LunaSocialUI
import UIKit
import XCTest
@testable import Luna

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

    /// iPhone-mini point size. The identity screen and the setup steps must keep all
    /// of their content (icon/title/body/fields) and buttons reachable here — the
    /// fields live in a scroll view and the buttons stay pinned and in-bounds.
    private static let miniSize = CGSize(width: 375, height: 812)

    /// On a small screen the identity step keeps its Continue button on-screen, its
    /// content inside a scroll view, and its fields laid out within view bounds.
    func testIdentityStepFitsSmallScreen() {
        let username = OnboardingViewController(onComplete: {})
        let window = UITestSupport.host(username, size: Self.miniSize)

        let scrollViews = allScrollViews(in: username.view)
        XCTAssertGreaterThan(scrollViews.count, 0, "identity content should be scrollable on small screens")

        let buttons = allButtons(in: username.view)
        XCTAssertGreaterThan(buttons.count, 0)
        for button in buttons {
            LayoutAssertions.assertVisibleAndInBounds(button, in: username.view)
        }

        let fields = allTextFields(in: username.view)
        XCTAssertEqual(fields.count, 3, "username + email + phone fields")
        for field in fields {
            LayoutAssertions.assertVisibleAndInBounds(field, in: username.view)
        }
        _ = window
    }

    /// Every setup step keeps its primary/continue buttons on-screen on a small device.
    func testSetupStepsFitSmallScreen() {
        let steps = OnboardingFlow.stepViewControllersForTesting()
        for step in steps.dropFirst() {
            let window = UITestSupport.host(step, size: Self.miniSize)
            let buttons = allButtons(in: step.view)
            for button in buttons where !button.isHidden {
                LayoutAssertions.assertVisibleAndInBounds(button, in: step.view)
            }
            _ = window
        }
    }

    private func allScrollViews(in view: UIView) -> [UIScrollView] {
        var found: [UIScrollView] = []
        if let scroll = view as? UIScrollView { found.append(scroll) }
        for subview in view.subviews { found.append(contentsOf: allScrollViews(in: subview)) }
        return found
    }

    private func allTextFields(in view: UIView) -> [UITextField] {
        var found: [UITextField] = []
        if let field = view as? UITextField { found.append(field) }
        for subview in view.subviews { found.append(contentsOf: allTextFields(in: subview)) }
        return found
    }

    private func allButtons(in view: UIView) -> [UIButton] {
        var found: [UIButton] = []
        if let button = view as? UIButton { found.append(button) }
        for subview in view.subviews { found.append(contentsOf: allButtons(in: subview)) }
        return found
    }
}

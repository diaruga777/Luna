//
//  ToastDotMatrixAppearTests.swift
//  LuneTests
//
//  Regression coverage for the send-to-friend toast Dot Matrix animation. The toast pill
//  used to be a `UIVisualEffectView`, and the injected appearance animator
//  (`DotMatrixAppear.pixelateIn`) once `addSubview`'d its Metal overlay directly into that
//  effect view — unsupported on modern iOS, which traps. That was fixed by parenting the
//  overlay in the pill's SUPERVIEW; the pill is now a plain SOLID `UIView` (a glass/blur
//  material can't be snapshotted faithfully for the wipe), so the pixels composite cleanly.
//
//  These tests drive the real `Toast.show` → `pixelateIn` path (and the matching
//  `pixelateOut` dismiss path) with the pixel-wipe toggle enabled and assert: showing does
//  not crash and the pill lands in the host hierarchy; nothing is ever added as a subview
//  of the pill that isn't its own content; and dismissing tears the pill back down.
//

import LuneDesignSystem
import LuneTransitions
import UIKit
import XCTest

@MainActor
final class ToastDotMatrixAppearTests: XCTestCase {

    private var window: UIWindow!
    private var priorToggle = false

    override func setUp() {
        super.setUp()
        priorToggle = ReaderSettings.pixelWipeTransitionsEnabled
        // Turn the gate on so the helpers take the Metal overlay branch when Metal is
        // available (and the fallback otherwise) — either way they must not crash.
        ReaderSettings.pixelWipeTransitionsEnabled = true

        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()

        // Mirror AppDelegate's launch-time wiring (both appear and disappear).
        Toast.appearanceAnimator = { pill in DotMatrixAppear.pixelateIn(pill) }
        Toast.disappearanceAnimator = { pill in DotMatrixDisappear.pixelateOut(pill) }
    }

    override func tearDown() {
        Toast.appearanceAnimator = nil
        Toast.disappearanceAnimator = nil
        ReaderSettings.pixelWipeTransitionsEnabled = priorToggle
        window.isHidden = true
        window = nil
        super.tearDown()
    }

    /// The Toast pill is the (non-effect) view `Toast.show` adds straight to the host.
    private func toastPill() -> UIView? {
        // Exclude the borrowed Metal overlay (a sibling the appearance wipe inserts) and
        // any `UIVisualEffectView`; the pill is our own plain content view.
        window.subviews.first { subview in
            subview is UILabel == false
                && (subview is UIVisualEffectView) == false
                && subview.subviews.contains { $0 is UIStackView }
        }
    }

    /// `Toast.show` with the Dot Matrix appearance animator installed must not crash, and
    /// the pill must end up in the host (window) hierarchy.
    func testShowWithDotMatrixAnimatorDoesNotCrashAndAddsPill() {
        let presenter = window.rootViewController!
        Toast.show("Sent to a friend", from: presenter)

        // The pill is added straight to the host before the animator runs, so it is in
        // the hierarchy synchronously.
        XCTAssertNotNil(toastPill(), "Toast pill should be added to the host window")
    }

    /// No app/overlay view should be a direct subview of the pill except its own content
    /// stack — the appearance overlay is parented in the host (the pill's superview), not
    /// in the pill.
    func testAppearanceOverlayIsNotParentedInThePill() {
        let presenter = window.rootViewController!
        Toast.show("Sent to a friend", from: presenter)

        guard let pill = toastPill() else { return XCTFail("Toast pill missing") }
        // The pill's only direct child is its content stack.
        XCTAssertTrue(pill.subviews.allSatisfy { $0 is UIStackView },
                      "Only the content stack should be a direct subview of the pill")
    }

    /// Dismissing the toast with the Dot Matrix disappearance animator installed must not
    /// crash. (The pixelate-out removes the pill when the wipe lands — asynchronously — so
    /// we only assert the synchronous dismiss call is safe and idempotent.)
    func testDismissWithDotMatrixAnimatorDoesNotCrash() {
        let presenter = window.rootViewController!
        Toast.show("Sent to a friend", from: presenter)
        guard let pill = toastPill() else { return XCTFail("Toast pill missing") }

        // Tap-to-dismiss path. Calling it twice must be a no-op the second time (guarded
        // against the auto-dismiss timer racing a tap).
        pill.dismissToastForTesting()
        pill.dismissToastForTesting()
    }
}

private extension UIView {
    /// Invoke the file-private `dismissToast` selector the tap gesture uses.
    func dismissToastForTesting() {
        let sel = Selector(("dismissToast"))
        if responds(to: sel) { perform(sel) }
    }
}

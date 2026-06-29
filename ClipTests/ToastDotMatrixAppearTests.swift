//
//  ToastDotMatrixAppearTests.swift
//  ClipTests
//
//  Regression coverage for the send-to-friend toast crash: `Toast.show` builds its
//  pill as a `UIVisualEffectView`, and the injected Dot Matrix appearance animator
//  (`DotMatrixAppear.pixelateIn`) used to `addSubview` its Metal overlay directly into
//  that effect view — unsupported on modern iOS, which traps. The fix parents the
//  overlay in the pill's SUPERVIEW (the toast host) instead. These tests drive the
//  real `Toast.show` → `pixelateIn` path with the pixel-wipe toggle enabled and assert
//  it does not crash, the pill lands in the host hierarchy, and — crucially — nothing
//  is ever added as a subview of the visual-effect pill itself.
//

import ClipDesignSystem
import ClipTransitions
import UIKit
import XCTest

@MainActor
final class ToastDotMatrixAppearTests: XCTestCase {

    private var window: UIWindow!
    private var priorToggle = false

    override func setUp() {
        super.setUp()
        priorToggle = ReaderSettings.pixelWipeTransitionsEnabled
        // Turn the gate on so `pixelateIn` takes the Metal overlay branch when Metal is
        // available (and the fallback otherwise) — either way it must not crash.
        ReaderSettings.pixelWipeTransitionsEnabled = true

        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()

        // Mirror AppDelegate's launch-time wiring.
        Toast.appearanceAnimator = { pill in DotMatrixAppear.pixelateIn(pill) }
    }

    override func tearDown() {
        Toast.appearanceAnimator = nil
        ReaderSettings.pixelWipeTransitionsEnabled = priorToggle
        window.isHidden = true
        window = nil
        super.tearDown()
    }

    /// `Toast.show` with the Dot Matrix appearance animator installed must not crash, and
    /// the visual-effect pill must end up in the host (window) hierarchy.
    func testShowWithDotMatrixAnimatorDoesNotCrashAndAddsPill() {
        let presenter = window.rootViewController!
        Toast.show("Sent to a friend", from: presenter)

        // The pill is added straight to the host before the animator runs, so it is in
        // the hierarchy synchronously.
        let pill = window.subviews.compactMap { $0 as? UIVisualEffectView }.first
        XCTAssertNotNil(pill, "Toast pill should be added to the host window")
    }

    /// The overlay (or any view) must never be parented inside the visual-effect pill —
    /// that is the exact unsupported operation that traps. The pill's only descendants
    /// are its own content (the stack/label/icon) under `contentView`.
    func testNoSubviewIsAddedDirectlyToTheVisualEffectPill() {
        let presenter = window.rootViewController!
        Toast.show("Sent to a friend", from: presenter)

        guard let pill = window.subviews.compactMap({ $0 as? UIVisualEffectView }).first else {
            return XCTFail("Toast pill missing")
        }
        // A `UIVisualEffectView` exposes `contentView` as a private backing subview; the
        // contract we assert is that we never add OUR OWN views as direct subviews of the
        // effect view. The content (stack) lives under `contentView`, never directly on
        // the pill, and no Metal overlay is parented on the pill.
        let directChildrenAreEffectInternalsOnly = pill.subviews.allSatisfy { child in
            child === pill.contentView || child.subviews.contains(where: { $0 === pill.contentView })
                || String(describing: type(of: child)).contains("Effect")
                || String(describing: type(of: child)).contains("Backdrop")
        }
        XCTAssertTrue(directChildrenAreEffectInternalsOnly,
                      "No app/overlay view should be a direct subview of the visual-effect pill")
    }
}

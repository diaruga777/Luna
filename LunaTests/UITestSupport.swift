//
//  UITestSupport.swift
//  LunaTests
//
//  Shared helpers for the screen snapshot + navigation/layout tests: seeding the
//  process-wide store with a deterministic fixture, hosting a view controller for a
//  real layout pass, and basic layout sanity assertions.
//

import LunaStorage
import LunaModels
import UIKit
import XCTest
@testable import Luna

enum UITestSupport {
    /// Seeds `ReadingListStore.shared` with a named fixture (reusing the exact same
    /// path the in-app `UITestSeeder` uses) and disables animations. Returns the
    /// fixture's items for convenience. Call in `setUp`; pair with `wipeSharedStore`
    /// in `tearDown` so tests don't leak state into each other or onto the device.
    @discardableResult
    static func seedSharedStore(_ state: UITestState) -> [ReadingListItem] {
        UIView.setAnimationsEnabled(false)
        UITestSeeder.seedSharedStore(state)
        return state.fixture.items
    }

    /// Empties the shared store after a test and clears the pinned sectioning clock.
    static func wipeSharedStore() {
        ReadingListStore.shared.wipeForTesting()
        UITestSeeder.sectioningNow = nil
    }

    /// Hosts `viewController` in a window at `size`, forces a layout pass, and runs
    /// the run loop briefly so async-to-main table reloads settle. Returns the
    /// window so the caller can keep it alive for the duration of the assertions
    /// (a deallocated window tears down the VC mid-test).
    @discardableResult
    static func host(
        _ viewController: UIViewController,
        size: CGSize = SnapshotTesting.phoneSize
    ) -> UIWindow {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        viewController.view.frame = window.bounds
        viewController.view.setNeedsLayout()
        viewController.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        viewController.view.layoutIfNeeded()
        return window
    }
}

/// Basic layout-sanity assertions reused across navigation tests: a critical view
/// must be on-screen, non-zero, and within its host's bounds.
enum LayoutAssertions {
    /// Asserts `subview` has a non-zero size and lies (mostly) within `container`'s
    /// bounds — i.e. it's laid out and not pushed off-screen or collapsed.
    static func assertVisibleAndInBounds(
        _ subview: UIView, in container: UIView,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(subview.isHidden, "view is hidden", file: file, line: line)
        XCTAssertGreaterThan(subview.bounds.width, 0, "zero width", file: file, line: line)
        XCTAssertGreaterThan(subview.bounds.height, 0, "zero height", file: file, line: line)
        let frameInContainer = subview.convert(subview.bounds, to: container)
        XCTAssertTrue(
            container.bounds.intersects(frameInContainer),
            "view frame \(frameInContainer) is outside container bounds \(container.bounds)",
            file: file, line: line)
    }

    /// Asserts the two frames (in the same coordinate space) do not overlap.
    static func assertNoOverlap(
        _ a: CGRect, _ b: CGRect,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(a.intersects(b), "frames overlap: \(a) ∩ \(b)", file: file, line: line)
    }
}

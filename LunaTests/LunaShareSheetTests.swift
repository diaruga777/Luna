//
//  LunaShareSheetTests.swift
//  LunaTests
//
//  Covers the shared share-sheet presenter every hand-rolled
//  UIActivityViewController call site now goes through: the four ways a caller
//  can anchor the iPad popover, and the safe fallback — a centered point over
//  the presenter's own view — used when no anchor view is available. That
//  fallback is what let `ProductCardPresenter.share` and `MediaCardPresenter`'s
//  two share paths drop a force-unwrapped `presentingController.view!` without
//  risking a crash.
//
//  These tests go through `makeActivityViewController` rather than a real
//  `present(animated:)` round trip: `UIActivityViewController` finishes
//  attaching to its window asynchronously (it queries available activities in
//  the background first), so `presentedViewController` isn't reliably
//  populated in a bare test window — no test in this suite presents one for
//  that reason. Building without presenting is deterministic and exercises
//  the exact same anchor-configuration code `present` calls.
//

@testable import LunaDesignSystem
import UIKit
import XCTest

final class LunaShareSheetTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UIView.setAnimationsEnabled(false)
    }

    @MainActor
    func testViewAnchorSetsSourceViewOnly() throws {
        let host = UIViewController()
        let window = UITestSupport.host(host)
        let anchorView = UIView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        host.view.addSubview(anchorView)

        let activity = try XCTUnwrap(LunaShareSheet.makeActivityViewController(
            items: ["hello"], from: host, anchor: .view(anchorView),
            applicationActivities: nil, completion: nil))

        let popover = try XCTUnwrap(activity.popoverPresentationController)
        XCTAssertEqual(popover.sourceView, anchorView)
        _ = window
    }

    @MainActor
    func testViewBoundsAnchorSetsSourceViewAndItsFullBounds() throws {
        let host = UIViewController()
        let window = UITestSupport.host(host)
        let anchorView = UIView(frame: CGRect(x: 0, y: 0, width: 60, height: 30))
        host.view.addSubview(anchorView)

        let activity = try XCTUnwrap(LunaShareSheet.makeActivityViewController(
            items: ["hello"], from: host, anchor: .viewBounds(anchorView),
            applicationActivities: nil, completion: nil))

        let popover = try XCTUnwrap(activity.popoverPresentationController)
        XCTAssertEqual(popover.sourceView, anchorView)
        XCTAssertEqual(popover.sourceRect, anchorView.bounds)
        _ = window
    }

    @MainActor
    func testRectAnchorSetsACustomRectWithinTheGivenView() throws {
        let host = UIViewController()
        let window = UITestSupport.host(host)
        let anchorView = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        host.view.addSubview(anchorView)
        let rect = CGRect(x: 10, y: 20, width: 1, height: 1)

        let activity = try XCTUnwrap(LunaShareSheet.makeActivityViewController(
            items: ["hello"], from: host, anchor: .rect(rect, in: anchorView),
            applicationActivities: nil, completion: nil))

        let popover = try XCTUnwrap(activity.popoverPresentationController)
        XCTAssertEqual(popover.sourceView, anchorView)
        XCTAssertEqual(popover.sourceRect, rect)
        _ = window
    }

    @MainActor
    func testBarButtonItemAnchorSetsTheBarButtonItem() throws {
        let host = UIViewController()
        let window = UITestSupport.host(host)
        let item = UIBarButtonItem(systemItem: .action)

        let activity = try XCTUnwrap(LunaShareSheet.makeActivityViewController(
            items: ["hello"], from: host, anchor: .barButtonItem(item),
            applicationActivities: nil, completion: nil))

        let popover = try XCTUnwrap(activity.popoverPresentationController)
        XCTAssertEqual(popover.barButtonItem, item)
        _ = window
    }

    /// `[BUGFIX]` `ProductCardPresenter.share` and both of `MediaCardPresenter`'s
    /// share paths force-unwrapped `host.presentingController.view!` when no
    /// card view was available. The anchor is optional now: a nil anchor
    /// lands here, a centered point over the presenter's own view, rather
    /// than crashing if the view somehow weren't loaded.
    @MainActor
    func testNilAnchorFallsBackToACenteredPointOverThePresentersOwnView() throws {
        let host = UIViewController()
        let window = UITestSupport.host(host)

        let activity = try XCTUnwrap(LunaShareSheet.makeActivityViewController(
            items: ["hello"], from: host, anchor: nil,
            applicationActivities: nil, completion: nil))

        // `UIPopoverPresentationController` treats a sourceView that IS the
        // presenting controller's own root view specially (it can normalize
        // sourceView to nil and nudge the geometry by a point or so) — the
        // same thing the original hand-rolled `host.view`-anchored call sites
        // (e.g. `LinkRSVPPreview`) already lived with, so this checks the
        // shape (a tiny, centered rect) rather than exact identity/values.
        let popover = try XCTUnwrap(activity.popoverPresentationController)
        XCTAssertEqual(popover.sourceRect.width, 1)
        XCTAssertEqual(popover.sourceRect.height, 1)
        XCTAssertEqual(popover.sourceRect.midX, host.view.bounds.midX, accuracy: 1)
        XCTAssertEqual(popover.sourceRect.midY, host.view.bounds.midY, accuracy: 1)
        _ = window
    }

    /// A presenter whose view was never loaded is a no-op rather than a crash —
    /// the guard the fixed force-unwrap sites relied on implicitly (a presenting
    /// controller's view is always loaded in practice) is now explicit.
    @MainActor
    func testUnloadedPresenterBuildsNothing() {
        let host = UIViewController()
        XCTAssertFalse(host.isViewLoaded)

        let activity = LunaShareSheet.makeActivityViewController(
            items: ["hello"], from: host, anchor: nil,
            applicationActivities: nil, completion: nil)

        XCTAssertNil(activity)
        XCTAssertFalse(host.isViewLoaded)
    }

    /// `present(items:from:anchor:completion:)` itself is a no-op for the same
    /// unloaded presenter, rather than crashing or force-loading the view.
    @MainActor
    func testPresentIsANoOpForAnUnloadedPresenter() {
        let host = UIViewController()

        LunaShareSheet.present(items: ["hello"], from: host, anchor: nil)

        XCTAssertFalse(host.isViewLoaded)
        XCTAssertNil(host.presentedViewController)
    }

    /// Every site preserves its own completion handler.
    @MainActor
    func testCompletionHandlerIsAttached() throws {
        let host = UIViewController()
        let window = UITestSupport.host(host)
        var completionRan = false

        let activity = try XCTUnwrap(LunaShareSheet.makeActivityViewController(
            items: ["hello"], from: host, anchor: nil, applicationActivities: nil,
            completion: { _, _, _, _ in completionRan = true }))

        activity.completionWithItemsHandler?(nil, true, nil, nil)
        XCTAssertTrue(completionRan)
        _ = window
    }
}

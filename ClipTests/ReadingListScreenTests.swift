//
//  ReadingListScreenTests.swift
//  ClipTests
//
//  Snapshot + navigation/layout coverage for the reading list home screen across
//  the seeded UI-test states and the filter segments, plus row-tap routing to the
//  correct viewer per item type.
//

import UIKit
import XCTest
@testable import Clip

final class ReadingListScreenTests: XCTestCase {

    override func tearDown() {
        UITestSupport.wipeSharedStore()
        super.tearDown()
    }

    // MARK: - Snapshots per state

    func testReadingListEmptySnapshot() {
        UITestSupport.seedSharedStore(.empty)
        let nav = UINavigationController(rootViewController: ReadingListViewController())
        SnapshotTesting.assertSnapshot(of: nav, named: "reading-list-empty")
    }

    func testReadingListMixedSnapshot() {
        UITestSupport.seedSharedStore(.mixed)
        let nav = UINavigationController(rootViewController: ReadingListViewController())
        SnapshotTesting.assertSnapshot(of: nav, named: "reading-list-mixed")
    }

    func testReadingListCatchUpEligibleSnapshot() {
        UITestSupport.seedSharedStore(.catchUpEligible)
        let nav = UINavigationController(rootViewController: ReadingListViewController())
        SnapshotTesting.assertSnapshot(of: nav, named: "reading-list-catchup")
    }

    func testReadingListPriceTrackingSnapshot() {
        UITestSupport.seedSharedStore(.priceTracking)
        let nav = UINavigationController(rootViewController: ReadingListViewController())
        SnapshotTesting.assertSnapshot(of: nav, named: "reading-list-price-tracking")
    }

    // MARK: - Filter segments

    /// The mixed list has reader, media, and price-tracker kinds, so the filter
    /// control is visible. Snapshot each segment.
    func testReadingListFilterSegmentsSnapshot() {
        UITestSupport.seedSharedStore(.mixed)
        let viewController = ReadingListViewController()
        let nav = UINavigationController(rootViewController: viewController)
        let window = UITestSupport.host(nav)

        guard let control = findSegmentedControl(in: nav.view) else {
            XCTFail("filter segmented control not visible for mixed list")
            return
        }
        XCTAssertGreaterThanOrEqual(control.numberOfSegments, 2,
                                    "expected multiple filter segments")
        for segment in 0..<control.numberOfSegments {
            control.selectedSegmentIndex = segment
            control.sendActions(for: .valueChanged)
            viewController.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            SnapshotTesting.assertSnapshot(of: nav, named: "reading-list-filter-\(segment)")
        }
        _ = window
    }

    // MARK: - Navigation routing (row tap → correct viewer)

    func testRowTapRoutesArticleToReader() {
        UITestSupport.seedSharedStore(.mixed)
        let (viewController, nav, window) = hostedList()
        // Read from the store so the item carries its written contentFileName (the
        // fixture's in-memory copies don't — content files are keyed on disk).
        let stored = ReadingListStore.shared.items()
        let article = stored.first {
            $0.state == .ready && !$0.isPlatformItem && !$0.isPriceTracker
                && !$0.isDocument && $0.contentFileName != nil
        }
        guard let target = article else {
            XCTFail("no ready article with content in fixture"); return
        }

        viewController.open(target, presenter: viewController)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(nav.topViewController is ReaderViewController,
                      "ready article should push the reader, got \(String(describing: nav.topViewController))")
        _ = window
    }

    func testRowTapRoutesPriceTrackerToEditor() {
        let items = UITestSupport.seedSharedStore(.mixed)
        let (viewController, nav, window) = hostedList()
        guard let tracker = items.first(where: { $0.isPriceTracker }) else {
            XCTFail("no price tracker in fixture"); return
        }
        viewController.open(tracker, presenter: viewController)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(nav.topViewController is PriceTrackingViewController,
                      "price tracker should push the editor")
        _ = window
    }

    func testRowTapRoutesNeedsCaptchaToArchiveReader() {
        let items = UITestSupport.seedSharedStore(.mixed)
        let (viewController, _, window) = hostedList()
        guard let locked = items.first(where: { $0.state == .needsCaptcha }) else {
            XCTFail("no needsCaptcha item in fixture"); return
        }
        viewController.open(locked, presenter: viewController)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        // Archive reader is presented modally inside a nav controller.
        let presented = viewController.presentedViewController as? UINavigationController
        XCTAssertTrue(presented?.viewControllers.first is ArchiveWebReaderViewController,
                      "needsCaptcha item should present the archive web reader")
        viewController.dismiss(animated: false)
        _ = window
    }

    func testRowTapRoutesYouTubeWithoutPushingReader() {
        let items = UITestSupport.seedSharedStore(.mixed)
        let (viewController, nav, window) = hostedList()
        guard let video = items.first(where: { $0.isYouTubeVideo }) else {
            XCTFail("no YouTube item in fixture"); return
        }
        let handled = viewController.openItem(video, presentingFrom: viewController)
        XCTAssertTrue(handled, "openItem should claim a YouTube video")
        XCTAssertFalse(nav.topViewController is ReaderViewController,
                       "a video must not open the text reader")
        viewController.dismiss(animated: false)
        _ = window
    }

    func testPlatformPostsAreHandledByOpenItem() {
        let items = UITestSupport.seedSharedStore(.mixed)
        let (viewController, _, window) = hostedList()
        let platformPosts = items.filter { $0.isPlatformItem && !$0.isYouTubeVideo }
        XCTAssertGreaterThan(platformPosts.count, 0)
        for post in platformPosts {
            let handled = viewController.openItem(post, presentingFrom: viewController)
            XCTAssertTrue(handled, "openItem should claim platform item \(post.urlString)")
            viewController.dismiss(animated: false)
        }
        _ = window
    }

    // MARK: - Nav-bar button routing

    func testSettingsButtonPushesSettings() {
        UITestSupport.seedSharedStore(.empty)
        let (viewController, nav, window) = hostedList()
        invokeBarButton(named: "gearshape", in: viewController.navigationItem.leftBarButtonItems)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(nav.topViewController is SettingsViewController,
                      "settings button should push SettingsViewController")
        _ = window
    }

    func testFriendsButtonPushesFriends() {
        UITestSupport.seedSharedStore(.empty)
        let (viewController, nav, window) = hostedList()
        invokeBarButton(named: "person.2", in: viewController.navigationItem.leftBarButtonItems)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(nav.topViewController is FriendsViewController,
                      "friends button should push FriendsViewController")
        _ = window
    }

    func testCatchUpButtonPresentsCatchUp() {
        UITestSupport.seedSharedStore(.catchUpEligible)
        let (viewController, _, window) = hostedList()
        // The catch-up button action is private; exercise the same presentation seam
        // by performing its selector.
        viewController.perform(Selector(("catchUpTapped")))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(viewController.presentedViewController is CatchUpViewController,
                      "catch-up button should present the card stack")
        viewController.dismiss(animated: false)
        _ = window
    }

    // MARK: - Layout sanity

    func testReadingListLayoutHasOnScreenTable() {
        UITestSupport.seedSharedStore(.mixed)
        let (viewController, nav, window) = hostedList()
        LayoutAssertions.assertVisibleAndInBounds(viewController.tableView, in: nav.view)
        XCTAssertGreaterThan(viewController.tableView.numberOfSections, 0)
        _ = window
    }

    // MARK: - Helpers

    private func hostedList() -> (ReadingListViewController, UINavigationController, UIWindow) {
        let viewController = ReadingListViewController()
        let nav = UINavigationController(rootViewController: viewController)
        let window = UITestSupport.host(nav)
        return (viewController, nav, window)
    }

    private func invokeBarButton(named systemImageHint: String, in items: [UIBarButtonItem]?) {
        // Match the bar button by its action selector substring, since the system
        // image isn't reliably introspectable. Fall back to the first item with an
        // action whose name contains the hint mapping.
        let selectorHints: [String: String] = [
            "gearshape": "settingsTapped",
            "person.2": "friendsTapped",
        ]
        guard let items else { return }
        for item in items {
            guard let action = item.action else { continue }
            let name = NSStringFromSelector(action)
            if let hint = selectorHints[systemImageHint], name.contains(hint),
               let target = item.target {
                _ = target.perform(action, with: item)
                return
            }
        }
        XCTFail("no bar button matching \(systemImageHint)")
    }

    private func findSegmentedControl(in view: UIView) -> UISegmentedControl? {
        if let control = view as? UISegmentedControl { return control }
        for subview in view.subviews {
            if let found = findSegmentedControl(in: subview) { return found }
        }
        return nil
    }
}

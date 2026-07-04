//
//  ReadingListScreenTests.swift
//  LunaTests
//
//  Snapshot + navigation/layout coverage for the reading list home screen across
//  the seeded UI-test states and the filter segments, plus row-tap routing to the
//  correct viewer per item type.
//

import LunaReadingListUI
import LunaSocialUI
import LunaPriceUI
import LunaReaderUI
import LunaArchiveReader
import LunaStorage
import LunaDesignSystem
import UIKit
import XCTest
@testable import Luna

final class ReadingListScreenTests: XCTestCase {

    private var priorAnimatedTransitions = true

    override func setUp() {
        super.setUp()
        // Animated transitions are App-Group-persisted and default to on; these tests
        // assert the reader + filter chrome, so pin them off for hermeticity regardless
        // of any value left in the container.
        priorAnimatedTransitions = AppearanceSettings.animatedTransitionsEnabled
        AppearanceSettings.animatedTransitionsEnabled = false
    }

    override func tearDown() {
        AppearanceSettings.animatedTransitionsEnabled = priorAnimatedTransitions
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

    /// Regression guard for the de-nav-bar header layout on a device with a real top
    /// safe-area inset (Dynamic Island). Two bugs slipped past the ~0-inset snapshots:
    /// (1) the table-header container collapsed to its compressed width (~32pt), clipping
    /// the title + filter, because it was `translatesAutoresizingMaskIntoConstraints=false`
    /// with no width constraint; (2) the resting contentOffset didn't include the bar inset,
    /// so the large title hid under the pinned bar. This hosts the list at a realistic
    /// safe-area inset (set BEFORE first layout, as on device) and asserts the header is
    /// full-width and the title sits below the bar.
    func testHeaderLayoutWithRealisticSafeArea() {
        UITestSupport.seedSharedStore(.mixed)
        let viewController = ReadingListViewController()
        let nav = UINavigationController(rootViewController: viewController)
        let window = SafeAreaWindow(frame: CGRect(origin: .zero, size: SnapshotTesting.phoneSize))
        window.simulatedSafeAreaInsets = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = nav
        window.makeKeyAndVisible()
        nav.view.frame = window.bounds
        nav.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        nav.view.layoutIfNeeded()

        let tableView = viewController.tableView!
        // (1) The table header must span the full table width — not collapse to its
        // compressed content width.
        let header = tableView.tableHeaderView
        XCTAssertNotNil(header, "table header missing")
        XCTAssertEqual(header?.frame.width ?? 0, tableView.bounds.width, accuracy: 0.5,
                       "table header collapsed (expected full width \(tableView.bounds.width), got \(header?.frame.width ?? 0))")

        // (2) The large "Reading List" title must render below the pinned bar, not under it.
        guard let navBar = firstSubview(in: tableView, typeNameContains: "NavHeaderBar") else {
            XCTFail("pinned NavHeaderBar not found"); _ = window; return
        }
        guard let titleLabel = firstLabel(in: tableView, withText: "Reading List") else {
            XCTFail("large title label not found"); _ = window; return
        }
        let barMaxY = navBar.convert(navBar.bounds, to: window).maxY
        let titleMinY = titleLabel.convert(titleLabel.bounds, to: window).minY
        XCTAssertGreaterThanOrEqual(titleMinY, barMaxY - 2,
            "large title (minY \(titleMinY)) is hidden under the pinned bar (maxY \(barMaxY))")

        // The filter control is present and sits below the title.
        guard let filter = findSegmentedControl(in: nav.view) else {
            XCTFail("filter segmented control not visible"); _ = window; return
        }
        let filterMinY = filter.convert(filter.bounds, to: window).minY
        XCTAssertGreaterThanOrEqual(filterMinY, titleMinY - 2,
            "filter (minY \(filterMinY)) should sit below the title (minY \(titleMinY))")
        _ = window
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

    // MARK: - Per-app surface

    func testAppSurfaceBaseFilters() {
        XCTAssertEqual(AppSurface.reader.baseFilter, .articles)
        XCTAssertEqual(AppSurface.downloader.baseFilter, .mediaAndLinks)
        XCTAssertEqual(AppSurface.priceTracker.baseFilter, .priceTrackers)
    }

    /// A concrete surface (Luna Reader) shows only its category and hides the filter
    /// segments, even though the shared store also holds media + price-tracker items.
    func testReaderSurfaceHidesFilterAndScopesToArticles() {
        let items = UITestSupport.seedSharedStore(.mixed)
        let nav = UINavigationController(rootViewController: ReadingListViewController(surface: .reader))
        let window = UITestSupport.host(nav)

        XCTAssertNil(findSegmentedControl(in: nav.view),
                     "a single-category surface must not show the filter segments")
        // Sanity: the mixed fixture really does contain both reader and non-reader items,
        // so the surface scoping is doing meaningful work.
        let readerItems = items.filter { AppSurface.reader.includes($0) }
        XCTAssertGreaterThan(readerItems.count, 0, "fixture should contain reader items")
        XCTAssertLessThan(readerItems.count, items.count,
                          "fixture should also contain non-reader items the reader surface hides")
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
        XCTAssertTrue(nav.topViewController is RabbitHoleReaderViewController,
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
        XCTAssertFalse(nav.topViewController is RabbitHoleReaderViewController,
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
        // The settings control now lives in the in-content NavHeaderBar (not the nav
        // bar); exercise the same action seam by its selector.
        viewController.perform(#selector(ReadingListViewController.settingsTapped))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(nav.topViewController is SettingsViewController,
                      "settings button should push SettingsViewController")
        _ = window
    }

    func testFriendsButtonPushesFriends() {
        UITestSupport.seedSharedStore(.empty)
        let (viewController, nav, window) = hostedList()
        viewController.perform(#selector(ReadingListViewController.friendsTapped))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(nav.topViewController is FriendsViewController,
                      "friends button should push FriendsViewController")
        _ = window
    }

    func testCatchUpButtonPresentsCatchUp() {
        UITestSupport.seedSharedStore(.catchUpEligible)
        let (viewController, _, window) = hostedList()
        viewController.perform(#selector(ReadingListViewController.catchUpTapped))
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

    private func firstSubview(in view: UIView, typeNameContains name: String) -> UIView? {
        if String(describing: type(of: view)).contains(name) { return view }
        for subview in view.subviews {
            if let found = firstSubview(in: subview, typeNameContains: name) { return found }
        }
        return nil
    }

    private func firstLabel(in view: UIView, withText text: String) -> UILabel? {
        if let label = view as? UILabel, label.text == text { return label }
        for subview in view.subviews {
            if let found = firstLabel(in: subview, withText: text) { return found }
        }
        return nil
    }

    // The filter / mode switcher are the project's custom `LunaSegmentedControl`
    // (a UIControl), not a UIKit `UISegmentedControl`.
    private func findSegmentedControl(in view: UIView) -> LunaSegmentedControl? {
        if let control = view as? LunaSegmentedControl { return control }
        for subview in view.subviews {
            if let found = findSegmentedControl(in: subview) { return found }
        }
        return nil
    }
}

/// A window that reports a fixed safe-area inset (the test host's real window has none),
/// so a screen can be laid out exactly as it would be on a device with a Dynamic Island —
/// crucially with the inset known from the FIRST layout pass, matching real launch.
private final class SafeAreaWindow: UIWindow {
    var simulatedSafeAreaInsets: UIEdgeInsets = .zero {
        didSet { rootViewController?.view.setNeedsLayout() }
    }
    override var safeAreaInsets: UIEdgeInsets { simulatedSafeAreaInsets }
}

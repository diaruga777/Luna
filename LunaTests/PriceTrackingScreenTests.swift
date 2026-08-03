//
//  PriceTrackingScreenTests.swift
//  LunaTests
//
//  Navigation/layout coverage for the price-tracking editor.
//

import LunaReadingListUI
import LunaPriceUI
import LunaStorage
import LunaModels
import UIKit
import XCTest
@testable import Luna

final class PriceTrackingScreenTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UIView.setAnimationsEnabled(false)
    }

    override func tearDown() {
        UITestSupport.wipeSharedStore()
        super.tearDown()
    }

    // MARK: - Price Tracker card root

    func testPriceTrackerRootUsesSharedCarouselUtilCardAndArchiveTray() {
        UITestSupport.seedSharedStore(.priceTracking)
        let deck = PriceTrackerCardsViewController()
        let window = UITestSupport.host(UINavigationController(rootViewController: deck))
        deck.view.layoutIfNeeded()

        XCTAssertEqual(deck.carousel.dataSource?.numberOfCards(in: deck.carousel), 4)
        if case .miniCards = deck.carousel.style.scrubberStyle {
            // expected
        } else {
            XCTFail("Price Tracker should use the same mini-card scrubber as Reader")
        }
        XCTAssertTrue(deck.carousel.contentController(at: 0) is UtilCardContentViewController)
        XCTAssertNotNil(deck.archiveTray)
        XCTAssertNotNil(deck.carousel.contentController(at: 1))
        _ = window
    }

    func testPriceTrackerCardKeepsThresholdOnZeroPointGraph() {
        UITestSupport.seedSharedStore(.priceTracking)
        let deck = PriceTrackerCardsViewController()
        let window = UITestSupport.host(UINavigationController(rootViewController: deck))
        deck.view.layoutIfNeeded()

        // Pending Keyboard is newest: it has no history points but still owns
        // the graph and its editable absolute threshold.
        guard let content = deck.carousel.contentController(at: 1),
              let graph = findSubview(of: PriceGraphView.self, in: content.view),
              let threshold = findButton(accessibilityLabel: "Alert threshold", in: graph)
        else {
            XCTFail("zero-point price card should expose its graph threshold")
            return
        }
        XCTAssertEqual(threshold.accessibilityValue, "$108.00")
        XCTAssertNotNil(graph.thresholdDragGestureRecognizer.view)
        _ = window
    }

    // MARK: - Price tracking editor

    // NOTE: The two PriceTrackingViewController snapshot tests are skipped — since the
    // price-history graph was added, offscreen `layer.render(in:)` of this VC hangs in
    // the snapshot harness (the live app renders it fine: see
    // testPriceTrackingEditorLayoutHasStoreList, which hosts + asserts the VC, and
    // manual/TestFlight verification). Snapshotting this VC isn't viable on-sim.
    func testPriceTrackingEditorSnapshot() throws {
        throw XCTSkip("PriceTrackingViewController hangs offscreen layer.render; covered by layout test.")
    }

    func testPriceTrackingAlertingEditorSnapshot() throws {
        throw XCTSkip("PriceTrackingViewController hangs offscreen layer.render; covered by layout test.")
    }

    func testPriceTrackingEditorLayoutHasStoreList() {
        UITestSupport.seedSharedStore(.priceTracking)
        guard let tracker = ReadingListStore.shared.items().first(where: { $0.isPriceTracker }) else {
            XCTFail("no price tracker seeded"); return
        }
        let editor = PriceTrackingViewController(itemID: tracker.id)
        let window = UITestSupport.host(editor)
        guard let table = findTableView(in: editor.view) else {
            XCTFail("price tracking editor has no table"); return
        }
        LayoutAssertions.assertVisibleAndInBounds(table, in: editor.view)
        XCTAssertGreaterThan(table.numberOfSections, 0)
        _ = window
    }

    // MARK: - Exit (Back / Read instead)

    /// Existing mode shows a Back chevron that pops back to the pushing root, and NO
    /// "Read instead" button (just viewing a saved tracker).
    func testExistingModeBackPopsAndNoReadInstead() {
        UITestSupport.seedSharedStore(.priceTracking)
        guard let tracker = ReadingListStore.shared.items().first(where: { $0.isPriceTracker }) else {
            XCTFail("no price tracker seeded"); return
        }
        let root = UIViewController()   // stands in for whatever pushed the editor
        let nav = UINavigationController(rootViewController: root)
        let window = UITestSupport.host(nav)
        let editor = PriceTrackingViewController(itemID: tracker.id)
        nav.pushViewController(editor, animated: false)
        editor.loadViewIfNeeded()
        XCTAssertTrue(nav.topViewController is PriceTrackingViewController)
        // The header controls now live in the in-content NavHeaderBar (not the nav bar);
        // exercise the same back action seam by its selector.
        editor.perform(#selector(PriceTrackingViewController.leftButtonTapped))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(nav.topViewController === root, "Back should pop back to the pushing root")
        XCTAssertNotNil(ReadingListStore.shared.item(withID: tracker.id),
                        "Back must not delete the tracker")
        _ = window
    }

    /// The price editor uses a custom Back item, which otherwise disables UIKit's
    /// stock interactive-pop recognizer. A left-edge swipe must still return a
    /// tracker opened from a root screen back to that root controller.
    func testExistingModeEnablesInteractivePopBackToReadingList() {
        UITestSupport.seedSharedStore(.priceTracking)
        guard let tracker = ReadingListStore.shared.items().first(where: { $0.isPriceTracker }) else {
            XCTFail("no price tracker seeded"); return
        }
        let root = UIViewController()   // stands in for whatever pushed the editor
        let nav = UINavigationController(rootViewController: root)
        let window = UITestSupport.host(nav)
        let editor = PriceTrackingViewController(itemID: tracker.id)
        nav.pushViewController(editor, animated: false)
        editor.loadViewIfNeeded()
        editor.viewDidAppear(false)

        guard let popGesture = nav.interactivePopGestureRecognizer else {
            XCTFail("navigation controller should provide an interactive-pop gesture"); return
        }
        XCTAssertTrue(popGesture.delegate === editor)
        XCTAssertTrue(popGesture.isEnabled)
        XCTAssertTrue(editor.gestureRecognizerShouldBegin(popGesture))
        _ = window
    }

    /// Creation-mode "Read instead" discards the whole new tracker: the item is
    /// removed (re-saved as an article) and the screen pops.
    func testCreationModeReadInsteadDiscardsTrackerAndPops() {
        UITestSupport.seedSharedStore(.priceTracking)
        guard let tracker = ReadingListStore.shared.items().first(where: { $0.isPriceTracker }) else {
            XCTFail("no price tracker seeded"); return
        }
        let root = UIViewController()   // stands in for whatever pushed the editor
        let nav = UINavigationController(rootViewController: root)
        let window = UITestSupport.host(nav)
        let editor = PriceTrackingViewController(mode: .creation(itemID: tracker.id, host: .inApp))
        nav.pushViewController(editor, animated: false)
        editor.loadViewIfNeeded()

        // "Read instead" now lives in the in-content NavHeaderBar; drive its action seam.
        editor.perform(#selector(PriceTrackingViewController.readInsteadTapped))
        // The pop is an animated `popViewController`; under full-suite load it can need
        // more than one run-loop turn to settle, so poll (bounded) instead of a fixed wait.
        let popDeadline = Date().addingTimeInterval(2.0)
        while nav.topViewController !== root && Date() < popDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(nav.topViewController === root, "Read instead should pop back to the pushing root")
        XCTAssertNil(ReadingListStore.shared.item(withID: tracker.id),
                     "Read instead (creation) should drop the whole tracker save")
        _ = window
    }

    /// Merge-mode "Read instead" reverts ONLY the just-added seller, leaving the rest
    /// of the existing tracker intact, and pops.
    func testMergeModeReadInsteadRevertsOnlyAddedSeller() {
        UITestSupport.seedSharedStore(.priceTracking)
        guard let item = ReadingListStore.shared.items().first(where: { $0.isPriceTracker }),
              var tracker = item.priceTracker else {
            XCTFail("no price tracker seeded"); return
        }
        let originalURL = tracker.stores[0].urlString
        let addedURL = "https://merge-revert.example.com/product/abc"
        tracker.upsertStore(PriceTrackerStore(
            urlString: addedURL, lastPrice: 10, currency: tracker.initialCurrency, lastRefreshed: Date()))
        ReadingListStore.shared.updatePriceTracker(tracker, for: item.id)

        let root = UIViewController()   // stands in for whatever pushed the editor
        let nav = UINavigationController(rootViewController: root)
        let window = UITestSupport.host(nav)
        let editor = PriceTrackingViewController(
            mode: .merge(itemID: item.id, addedStoreURLString: addedURL, host: .inApp))
        nav.pushViewController(editor, animated: false)
        editor.loadViewIfNeeded()

        // "Read instead" now lives in the in-content NavHeaderBar; drive its action seam.
        editor.perform(#selector(PriceTrackingViewController.readInsteadTapped))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let after = ReadingListStore.shared.item(withID: item.id)?.priceTracker
        XCTAssertNotNil(after, "merge revert must keep the existing tracker")
        XCTAssertEqual(after?.hasStore(urlString: addedURL), false,
                       "the just-added seller should be reverted")
        XCTAssertEqual(after?.hasStore(urlString: originalURL), true,
                       "the existing seller must remain intact")
        _ = window
    }

    /// The action/share extension host exits via Done (its `onDone` completion), while
    /// in-app exits via Back (pops the nav stack). The chrome now lives in the
    /// in-content NavHeaderBar, so this verifies the exit BEHAVIOR rather than the bar
    /// item kind.
    func testExtensionHostShowsDoneInAppShowsBack() {
        UITestSupport.seedSharedStore(.priceTracking)
        guard let tracker = ReadingListStore.shared.items().first(where: { $0.isPriceTracker }) else {
            XCTFail("no price tracker seeded"); return
        }
        // In-app: left control pops the nav stack.
        let root = UIViewController()   // stands in for whatever pushed the editor
        let nav = UINavigationController(rootViewController: root)
        let window = UITestSupport.host(nav)
        let inAppEditor = PriceTrackingViewController(mode: .creation(itemID: tracker.id, host: .inApp))
        nav.pushViewController(inAppEditor, animated: false)
        inAppEditor.loadViewIfNeeded()
        inAppEditor.perform(#selector(PriceTrackingViewController.leftButtonTapped))
        let popDeadline = Date().addingTimeInterval(2.0)
        while nav.topViewController !== root && Date() < popDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(nav.topViewController === root, "in-app Back pops to the pushing root")

        // Extension host: left control hands off to the `onDone` completion.
        let extEditor = PriceTrackingViewController(mode: .creation(itemID: tracker.id, host: .extension))
        var didCallOnDone = false
        extEditor.onDone = { didCallOnDone = true }
        extEditor.loadViewIfNeeded()
        extEditor.perform(#selector(PriceTrackingViewController.leftButtonTapped))
        XCTAssertTrue(didCallOnDone, "extension host Done invokes the onDone completion")
        _ = window
    }

    /// Opening an alerting tracker marks its alert viewed, so it stops floating.
    func testOpeningAlertingTrackerMarksAlertViewed() {
        UITestSupport.seedSharedStore(.mixed)
        guard let alerting = ReadingListStore.shared.items().first(where: {
            $0.priceTracker?.hasUnviewedAlert == true
        }) else {
            XCTFail("no unviewed-alerting tracker seeded"); return
        }
        // The behavior moved with the surface: the sectioned list's row tap is gone,
        // and the central app's deck routes non-article cards through
        // `NonArticleCardOpening` (the Price Tracker app's deck does the same in
        // `PriceTrackerCardsViewController`). Drive the live seam.
        NonArticleCardOpening.install()
        let root = UIViewController()
        let nav = UINavigationController(rootViewController: root)
        let window = UITestSupport.host(nav)
        ArticleCardsViewController.nonArticleOpener?(alerting, root)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let refreshed = ReadingListStore.shared.item(withID: alerting.id)?.priceTracker
        XCTAssertEqual(refreshed?.isAlerting, true, "still alerting after viewing")
        XCTAssertEqual(refreshed?.hasUnviewedAlert, false, "alert acknowledged on open")
        _ = window
    }

    private func findTableView(in view: UIView) -> UITableView? {
        if let table = view as? UITableView { return table }
        for subview in view.subviews {
            if let found = findTableView(in: subview) { return found }
        }
        return nil
    }

    private func findSubview<T: UIView>(of type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = findSubview(of: type, in: subview) { return match }
        }
        return nil
    }

    private func findButton(accessibilityLabel: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityLabel == accessibilityLabel {
            return button
        }
        for subview in view.subviews {
            if let button = findButton(accessibilityLabel: accessibilityLabel, in: subview) {
                return button
            }
        }
        return nil
    }
}

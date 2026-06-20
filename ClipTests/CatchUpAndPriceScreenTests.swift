//
//  CatchUpAndPriceScreenTests.swift
//  ClipTests
//
//  Snapshot + navigation/layout coverage for the catch-up card stack and the
//  price-tracking editor.
//

import UIKit
import XCTest
@testable import Clip

final class CatchUpAndPriceScreenTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UIView.setAnimationsEnabled(false)
    }

    override func tearDown() {
        UITestSupport.wipeSharedStore()
        super.tearDown()
    }

    // MARK: - Catch-up

    /// The catch-up card stack renders its first card from the seeded unread queue.
    func testCatchUpCardStackSnapshot() {
        UITestSupport.seedSharedStore(.catchUpEligible)
        let router = ReadingListViewController()
        _ = UITestSupport.host(UINavigationController(rootViewController: router))
        let queue = ReadingListSectioning.catchUpQueue(items: ReadingListStore.shared.items())
        XCTAssertGreaterThanOrEqual(queue.count, 10, "catch-up fixture should be eligible")
        let catchUp = CatchUpViewController(unread: queue, router: router)
        SnapshotTesting.assertSnapshot(of: catchUp, named: "catchup-cards")
    }

    /// A locked (needsCaptcha) card appears in the queue and renders as a card.
    func testCatchUpWithLockedCardSnapshot() {
        UITestSupport.seedSharedStore(.mixed)
        let router = ReadingListViewController()
        _ = UITestSupport.host(UINavigationController(rootViewController: router))
        let queue = ReadingListSectioning.catchUpQueue(items: ReadingListStore.shared.items())
        let catchUp = CatchUpViewController(unread: queue, router: router)
        SnapshotTesting.assertSnapshot(of: catchUp, named: "catchup-mixed")
    }

    /// A price tracker surfaces as a catch-up card with the dedicated tracker layout:
    /// thumbnail, product name, per-store mini-table, and a READ-ONLY alert-threshold
    /// readout with a "Change" button (the slider lives on the full editor screen).
    func testCatchUpPriceTrackerCardSnapshot() {
        UITestSupport.seedSharedStore(.mixed)
        let trackers = ReadingListStore.shared.items().filter { $0.isPriceTracker }
        XCTAssertFalse(trackers.isEmpty, "mixed fixture should seed price trackers")
        let router = ReadingListViewController()
        _ = UITestSupport.host(UINavigationController(rootViewController: router))
        // Build a queue of just the trackers so the first card is a tracker card.
        let catchUp = CatchUpViewController(unread: trackers, router: router)
        SnapshotTesting.assertSnapshot(of: catchUp, named: "catchup-price-tracker")
    }

    func testCatchUpLayoutHasOnScreenContent() {
        UITestSupport.seedSharedStore(.catchUpEligible)
        let router = ReadingListViewController()
        _ = UITestSupport.host(UINavigationController(rootViewController: router))
        let queue = ReadingListSectioning.catchUpQueue(items: ReadingListStore.shared.items())
        let catchUp = CatchUpViewController(unread: queue, router: router)
        let window = UITestSupport.host(catchUp)
        // The card stack + bottom buttons should be laid out within bounds.
        XCTAssertGreaterThan(catchUp.view.subviews.count, 0)
        for subview in catchUp.view.subviews where !subview.isHidden && subview.bounds.height > 1 {
            LayoutAssertions.assertVisibleAndInBounds(subview, in: catchUp.view)
        }
        _ = window
    }

    // MARK: - Price tracking editor

    func testPriceTrackingEditorSnapshot() {
        UITestSupport.seedSharedStore(.priceTracking)
        guard let tracker = ReadingListStore.shared.items().first(where: { $0.isPriceTracker }) else {
            XCTFail("no price tracker seeded"); return
        }
        let editor = PriceTrackingViewController(itemID: tracker.id)
        SnapshotTesting.assertSnapshot(of: editor, named: "price-tracking-editor")
    }

    /// The alerting tracker (from the mixed fixture) renders its discount.
    func testPriceTrackingAlertingEditorSnapshot() {
        UITestSupport.seedSharedStore(.mixed)
        let alerting = ReadingListStore.shared.items().first {
            $0.priceTracker?.isAlerting == true
        }
        guard let alerting else { XCTFail("no alerting tracker seeded"); return }
        let editor = PriceTrackingViewController(itemID: alerting.id)
        SnapshotTesting.assertSnapshot(of: editor, named: "price-tracking-alerting")
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

    /// Existing mode shows a Back chevron that pops back to the reading list, and NO
    /// "Read instead" button (just viewing a saved tracker).
    func testExistingModeBackPopsAndNoReadInstead() {
        UITestSupport.seedSharedStore(.priceTracking)
        guard let tracker = ReadingListStore.shared.items().first(where: { $0.isPriceTracker }) else {
            XCTFail("no price tracker seeded"); return
        }
        let list = ReadingListViewController()
        let nav = UINavigationController(rootViewController: list)
        let window = UITestSupport.host(nav)
        let editor = PriceTrackingViewController(itemID: tracker.id)
        nav.pushViewController(editor, animated: false)
        editor.loadViewIfNeeded()
        XCTAssertTrue(nav.topViewController is PriceTrackingViewController)
        XCTAssertNil(editor.navigationItem.rightBarButtonItem,
                     "existing mode must NOT show a Read instead button")

        guard let back = editor.navigationItem.leftBarButtonItem, let action = back.action,
              let target = back.target else {
            XCTFail("existing mode should have a Back button"); return
        }
        _ = target.perform(action)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(nav.topViewController === list, "Back should pop back to the reading list")
        XCTAssertNotNil(ReadingListStore.shared.item(withID: tracker.id),
                        "Back must not delete the tracker")
        _ = window
    }

    /// Creation-mode "Read instead" discards the whole new tracker: the item is
    /// removed (re-saved as an article) and the screen pops.
    func testCreationModeReadInsteadDiscardsTrackerAndPops() {
        UITestSupport.seedSharedStore(.priceTracking)
        guard let tracker = ReadingListStore.shared.items().first(where: { $0.isPriceTracker }) else {
            XCTFail("no price tracker seeded"); return
        }
        let list = ReadingListViewController()
        let nav = UINavigationController(rootViewController: list)
        let window = UITestSupport.host(nav)
        let editor = PriceTrackingViewController(mode: .creation(itemID: tracker.id, host: .inApp))
        nav.pushViewController(editor, animated: false)
        editor.loadViewIfNeeded()

        guard let readInstead = editor.navigationItem.rightBarButtonItem,
              let action = readInstead.action, let target = readInstead.target else {
            XCTFail("creation mode should have a Read instead button"); return
        }
        _ = target.perform(action)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(nav.topViewController === list, "Read instead should pop back to the reading list")
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

        let list = ReadingListViewController()
        let nav = UINavigationController(rootViewController: list)
        let window = UITestSupport.host(nav)
        let editor = PriceTrackingViewController(
            mode: .merge(itemID: item.id, addedStoreURLString: addedURL, host: .inApp))
        nav.pushViewController(editor, animated: false)
        editor.loadViewIfNeeded()

        guard let readInstead = editor.navigationItem.rightBarButtonItem,
              let action = readInstead.action, let target = readInstead.target else {
            XCTFail("merge mode should have a Read instead button"); return
        }
        _ = target.perform(action)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let after = ReadingListStore.shared.item(withID: item.id)?.priceTracker
        XCTAssertNotNil(after, "merge revert must keep the existing tracker")
        XCTAssertEqual(after?.hasStore(urlString: addedURL), false,
                       "the just-added seller should be reverted")
        XCTAssertEqual(after?.hasStore(urlString: originalURL), true,
                       "the existing seller must remain intact")
        _ = window
    }

    /// The action/share extension host shows a Done button (not a Back chevron) as
    /// the way out, while in-app shows Back.
    func testExtensionHostShowsDoneInAppShowsBack() {
        UITestSupport.seedSharedStore(.priceTracking)
        guard let tracker = ReadingListStore.shared.items().first(where: { $0.isPriceTracker }) else {
            XCTFail("no price tracker seeded"); return
        }
        let inAppEditor = PriceTrackingViewController(mode: .creation(itemID: tracker.id, host: .inApp))
        inAppEditor.loadViewIfNeeded()
        XCTAssertNotNil(inAppEditor.navigationItem.leftBarButtonItem?.image,
                        "in-app left button is a back chevron image")

        let extEditor = PriceTrackingViewController(mode: .creation(itemID: tracker.id, host: .extension))
        extEditor.loadViewIfNeeded()
        XCTAssertNil(extEditor.navigationItem.leftBarButtonItem?.image,
                     "extension host left button is a system Done (no custom image)")
    }

    /// Opening an alerting tracker marks its alert viewed, so it stops floating.
    func testOpeningAlertingTrackerMarksAlertViewed() {
        UITestSupport.seedSharedStore(.mixed)
        guard let alerting = ReadingListStore.shared.items().first(where: {
            $0.priceTracker?.hasUnviewedAlert == true
        }) else {
            XCTFail("no unviewed-alerting tracker seeded"); return
        }
        let list = ReadingListViewController()
        let nav = UINavigationController(rootViewController: list)
        let window = UITestSupport.host(nav)
        list.open(alerting, presenter: list)
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
}

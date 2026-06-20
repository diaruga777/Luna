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

    // MARK: - Exit (Done / Cancel)

    /// Existing mode shows a working Done that pops back to the reading list.
    func testExistingModeDonePopsBack() {
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

        guard let done = editor.navigationItem.leftBarButtonItem, let action = done.action,
              let target = done.target else {
            XCTFail("existing mode should have a Done button"); return
        }
        _ = target.perform(action)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(nav.topViewController === list, "Done should pop back to the reading list")
        _ = window
    }

    /// Creation-mode Cancel backs out: the tracker item is removed and the screen pops.
    func testCreationModeCancelRemovesTrackerAndPops() {
        UITestSupport.seedSharedStore(.priceTracking)
        guard let tracker = ReadingListStore.shared.items().first(where: { $0.isPriceTracker }) else {
            XCTFail("no price tracker seeded"); return
        }
        let list = ReadingListViewController()
        let nav = UINavigationController(rootViewController: list)
        let window = UITestSupport.host(nav)
        let editor = PriceTrackingViewController(
            mode: .creation(itemID: tracker.id, isMerge: false, highlightedURL: nil))
        nav.pushViewController(editor, animated: false)
        editor.loadViewIfNeeded()

        guard let cancel = editor.navigationItem.leftBarButtonItem, let action = cancel.action,
              let target = cancel.target else {
            XCTFail("creation mode should have a Cancel button"); return
        }
        _ = target.perform(action)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(nav.topViewController === list, "Cancel should pop back to the reading list")
        XCTAssertNil(ReadingListStore.shared.item(withID: tracker.id),
                     "Cancel should drop the tracker save (re-saved as an article instead)")
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

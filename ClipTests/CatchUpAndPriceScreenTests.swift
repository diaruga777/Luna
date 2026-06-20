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
        SnapshotTesting.assertSnapshot(of: UINavigationController(rootViewController: editor),
                                       named: "price-tracking-editor")
    }

    /// The alerting tracker (from the mixed fixture) renders its discount.
    func testPriceTrackingAlertingEditorSnapshot() {
        UITestSupport.seedSharedStore(.mixed)
        let alerting = ReadingListStore.shared.items().first {
            $0.priceTracker?.isAlerting == true
        }
        guard let alerting else { XCTFail("no alerting tracker seeded"); return }
        let editor = PriceTrackingViewController(itemID: alerting.id)
        SnapshotTesting.assertSnapshot(of: UINavigationController(rootViewController: editor),
                                       named: "price-tracking-alerting")
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

    private func findTableView(in view: UIView) -> UITableView? {
        if let table = view as? UITableView { return table }
        for subview in view.subviews {
            if let found = findTableView(in: subview) { return found }
        }
        return nil
    }
}

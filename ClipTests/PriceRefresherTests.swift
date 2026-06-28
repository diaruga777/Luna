//
//  PriceRefresherTests.swift
//  ClipTests
//

import ClipPriceUI
import ClipStorage
import ClipHTMLClassification
import ClipModels
import XCTest
@testable import Clip

/// Coverage for `PriceRefresher`: stalest-first processing order, price updates,
/// newly-alerting detection, and resilience to a failing store fetch.
final class PriceRefresherTests: XCTestCase {

    /// In-memory persistence that records the order trackers were updated in.
    private final class FakeStore: PriceTrackerPersisting {
        var items: [ReadingListItem]
        private(set) var updateOrder: [UUID] = []

        init(_ items: [ReadingListItem]) { self.items = items }

        func priceTrackersStalestFirst() -> [ReadingListItem] {
            items.filter { $0.priceTracker?.isArchived == false }
                .sorted { ReadingListStore.stalestRefresh($0.priceTracker)
                    < ReadingListStore.stalestRefresh($1.priceTracker) }
        }

        func updatePriceTracker(_ tracker: PriceTracker, for itemID: UUID) -> ReadingListItem? {
            guard let index = items.firstIndex(where: { $0.id == itemID }) else { return nil }
            items[index].priceTracker = tracker
            updateOrder.append(itemID)
            return items[index]
        }
    }

    private func price(_ amount: String, currency: String = "USD") -> ProductPrice {
        ProductPrice(amount: Decimal(string: amount)!, currency: currency)
    }

    private func trackerItem(url: String, initialPrice: String, threshold: Double,
                             refreshedAt: Date) -> ReadingListItem {
        var item = ReadingListItem(urlString: url)
        var tracker = PriceTracker(
            productName: "Widget", firstStoreURL: url,
            price: Decimal(string: initialPrice)!, currency: "USD",
            alertThresholdFraction: threshold, now: refreshedAt)
        // Backdate the refresh stamp so ordering is controllable.
        tracker.setPrice(Decimal(string: initialPrice)!, currency: "USD",
                         urlString: url, at: refreshedAt)
        item.priceTracker = tracker
        return item
    }

    func testRefreshUpdatesPriceAndDetectsNewlyAlerting() async {
        let url = "https://shop.example/widget"
        let item = trackerItem(url: url, initialPrice: "100", threshold: 0.10,
                               refreshedAt: Date(timeIntervalSince1970: 0))
        let store = FakeStore([item])
        let fetcher = MockPriceFetcher()
        fetcher.priceByURL[url] = price("80")

        let refresher = PriceRefresher(store: store, priceFetcher: fetcher,
                                       now: { Date(timeIntervalSince1970: 10_000) })
        let outcomes = await refresher.refreshAll()

        XCTAssertEqual(outcomes.count, 1)
        let outcome = outcomes[0]
        XCTAssertEqual(outcome.previousBest, Decimal(string: "100"))
        XCTAssertEqual(outcome.newBest, Decimal(string: "80"))
        XCTAssertTrue(outcome.isAlerting)
        XCTAssertTrue(outcome.newlyAlerting)
        XCTAssertEqual(store.items[0].priceTracker?.currentBestPrice, Decimal(string: "80"))
    }

    func testAlreadyAlertingIsNotNewlyAlerting() async {
        let url = "https://shop.example/widget"
        var item = trackerItem(url: url, initialPrice: "100", threshold: 0.10,
                               refreshedAt: Date(timeIntervalSince1970: 0))
        // Seed already-discounted (and thus already alerting) state.
        item.priceTracker?.setPrice(Decimal(string: "70"), currency: "USD", urlString: url,
                                    at: Date(timeIntervalSince1970: 0))
        let store = FakeStore([item])
        let fetcher = MockPriceFetcher()
        fetcher.priceByURL[url] = price("65")

        let outcomes = await PriceRefresher(store: store, priceFetcher: fetcher).refreshAll()
        XCTAssertTrue(outcomes[0].isAlerting)
        XCTAssertFalse(outcomes[0].newlyAlerting)
    }

    func testProcessesStalestFirst() async {
        let freshURL = "https://fresh.example/p"
        let staleURL = "https://stale.example/p"
        let fresh = trackerItem(url: freshURL, initialPrice: "10", threshold: 0.1,
                                refreshedAt: Date(timeIntervalSince1970: 9000))
        let stale = trackerItem(url: staleURL, initialPrice: "10", threshold: 0.1,
                                refreshedAt: Date(timeIntervalSince1970: 100))
        let store = FakeStore([fresh, stale])
        let fetcher = MockPriceFetcher()
        fetcher.priceByURL[freshURL] = price("10")
        fetcher.priceByURL[staleURL] = price("10")

        let outcomes = await PriceRefresher(store: store, priceFetcher: fetcher).refreshAll()
        XCTAssertEqual(outcomes.map(\.itemID), [stale.id, fresh.id])
        XCTAssertEqual(store.updateOrder, [stale.id, fresh.id])
    }

    func testFailingFetchLeavesPriceUnchanged() async {
        let url = "https://shop.example/widget"
        let item = trackerItem(url: url, initialPrice: "100", threshold: 0.1,
                               refreshedAt: Date(timeIntervalSince1970: 0))
        let store = FakeStore([item])
        // No price stubbed for the URL → the fetcher yields nil (all methods failed).
        let fetcher = MockPriceFetcher()

        let outcomes = await PriceRefresher(store: store, priceFetcher: fetcher).refreshAll()
        XCTAssertEqual(outcomes[0].newBest, Decimal(string: "100"))
        XCTAssertFalse(outcomes[0].isAlerting)
    }

    func testArchivedTrackerSkipped() async {
        let url = "https://shop.example/widget"
        var item = trackerItem(url: url, initialPrice: "100", threshold: 0.1,
                               refreshedAt: Date(timeIntervalSince1970: 0))
        item.priceTracker?.isArchived = true
        let store = FakeStore([item])
        let fetcher = MockPriceFetcher()
        fetcher.priceByURL[url] = price("10")

        let outcomes = await PriceRefresher(store: store, priceFetcher: fetcher).refreshAll()
        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertTrue(fetcher.requestedURLs.isEmpty)
    }
}

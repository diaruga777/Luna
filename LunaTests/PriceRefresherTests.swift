//
//  PriceRefresherTests.swift
//  LunaTests
//

import LunaPriceUI
import LunaStorage
import LunaHTMLClassification
import LunaModels
import XCTest
@testable import Luna

/// Coverage for `PriceRefresher`: stalest-first processing order, price updates,
/// newly-alerting detection, and resilience to a failing store fetch.
final class PriceRefresherTests: XCTestCase {

    /// In-memory persistence that records the order trackers were updated in.
    private final class FakeStore: PriceTrackerPersisting {
        var items: [ReadingListItem]
        private(set) var updateOrder: [UUID] = []
        /// Rows whose sort date was stamped, in order — an alert firing must
        /// resurface its product, and only on the transition.
        private(set) var bumped: [UUID] = []

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

        func bump(_ itemID: UUID) {
            bumped.append(itemID)
            guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
            items[index].bumpDate = Date()
        }

        func item(withID itemID: UUID) -> ReadingListItem? {
            items.first { $0.id == itemID }
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

    // MARK: - Single-tracker refresh (Feature 1's post-seed immediate refresh)

    func testRefreshTrackerByIDRefreshesExactlyOneTracker() async {
        let seededURL = "https://shop.example/seeded"
        let otherURL = "https://shop.example/other"
        let seeded = trackerItem(url: seededURL, initialPrice: "100", threshold: 0.1,
                                 refreshedAt: Date(timeIntervalSince1970: 5000))
        let other = trackerItem(url: otherURL, initialPrice: "50", threshold: 0.1,
                                refreshedAt: Date(timeIntervalSince1970: 0))
        let store = FakeStore([seeded, other])
        let fetcher = MockPriceFetcher()
        fetcher.priceByURL[seededURL] = price("80")
        fetcher.priceByURL[otherURL] = price("10")

        let refresher = PriceRefresher(store: store, priceFetcher: fetcher)
        let outcome = await refresher.refreshTracker(itemID: seeded.id)

        XCTAssertEqual(outcome?.itemID, seeded.id)
        XCTAssertEqual(outcome?.newBest, Decimal(string: "80"))
        // The OTHER tracker must be untouched — this is a single-tracker
        // refresh, not a scoped `refreshAll`.
        XCTAssertEqual(store.updateOrder, [seeded.id])
        XCTAssertEqual(store.items.first { $0.id == other.id }?.priceTracker?.currentBestPrice,
                       Decimal(string: "50"))
    }

    func testRefreshTrackerByIDReturnsNilForAnUnknownItem() async {
        let store = FakeStore([])
        let outcome = await PriceRefresher(store: store, priceFetcher: MockPriceFetcher())
            .refreshTracker(itemID: UUID())
        XCTAssertNil(outcome)
    }

    /// `newlyAlerting` semantics are unchanged on the single-tracker path.
    func testRefreshTrackerByIDDetectsNewlyAlerting() async {
        let url = "https://shop.example/widget"
        let item = trackerItem(url: url, initialPrice: "100", threshold: 0.10,
                               refreshedAt: Date(timeIntervalSince1970: 0))
        let store = FakeStore([item])
        let fetcher = MockPriceFetcher()
        fetcher.priceByURL[url] = price("80")

        let outcome = await PriceRefresher(store: store, priceFetcher: fetcher)
            .refreshTracker(itemID: item.id)
        XCTAssertTrue(outcome?.isAlerting ?? false)
        XCTAssertTrue(outcome?.newlyAlerting ?? false)
    }
}

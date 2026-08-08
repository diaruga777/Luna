//
//  PriceComparisonBaselineTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaModels
import LunaPriceUI
import LunaStorage
import XCTest
@testable import Luna

/// `PriceTracker.medianStorePrice` + `seedComparisonBaseline`: the save-time
/// alternative-seller fan-out's baseline semantics
/// (`claudedocs/price-comparison.md`). Two guarantees are load-bearing —
/// the median is the going rate (not the cheapest seller), and seeding it can
/// never badge or notify.
final class PriceComparisonBaselineTests: XCTestCase {

    private func store(_ url: String, _ price: String?, currency: String = "USD") -> PriceTrackerStore {
        PriceTrackerStore(
            urlString: url, lastPrice: price.flatMap { Decimal(string: $0) },
            currency: currency, lastRefreshed: Date())
    }

    private func tracker(_ stores: [PriceTrackerStore], threshold: Double? = 0.10) -> PriceTracker {
        PriceTracker(productName: "Widget", stores: stores, alertThresholdFraction: threshold)
    }

    // MARK: - Median

    func testOddCountTakesTheMiddleValue() {
        let subject = tracker([
            store("https://a.example/p", "90"),
            store("https://b.example/p", "100"),
            store("https://c.example/p", "130"),
        ])
        XCTAssertEqual(subject.medianStorePrice?.amount, Decimal(string: "100"))
        XCTAssertEqual(subject.medianStorePrice?.currency, "USD")
    }

    func testEvenCountAveragesTheMiddleTwo() {
        let subject = tracker([
            store("https://a.example/p", "90"),
            store("https://b.example/p", "100"),
            store("https://c.example/p", "120"),
            store("https://d.example/p", "130"),
        ])
        XCTAssertEqual(subject.medianStorePrice?.amount, Decimal(string: "110"))
    }

    func testMedianIsIndependentOfStoreOrder() {
        let prices = ["130", "90", "100", "120"]
        let forward = tracker(prices.enumerated().map { store("https://s\($0.offset).example/p", $0.element) })
        let reversed = tracker(prices.reversed().enumerated()
            .map { store("https://s\($0.offset).example/p", $0.element) })
        XCTAssertEqual(forward.medianStorePrice?.amount, reversed.medianStorePrice?.amount)
    }

    func testForeignCurrencyAndPricelessStoresAreExcluded() {
        // There is no FX source, so a GBP listing cannot join a USD median.
        let subject = tracker([
            store("https://a.example/p", "90"),
            store("https://b.example/p", "100"),
            store("https://c.example/p", "5", currency: "GBP"),
            store("https://d.example/p", nil),
        ])
        XCTAssertEqual(subject.medianStorePrice?.amount, Decimal(string: "95"))
    }

    func testMedianIsNilWhenNoStoreHasADisplayCurrencyPrice() {
        var subject = tracker([store("https://a.example/p", nil)])
        subject.initialCurrency = "USD"
        XCTAssertNil(subject.medianStorePrice)
        XCTAssertFalse(subject.seedComparisonBaseline())
    }

    // MARK: - Seeding

    func testSeedingRebasesTheBaselineOntoTheMedianNotTheCheapestSeller() {
        var subject = tracker([
            store("https://source.example/p", "100"),
            store("https://cheap.example/p", "70"),
            store("https://dear.example/p", "130"),
        ])
        // The multi-store initializer starts from the LOWEST store, which is
        // exactly the wrong reference point after a fan-out.
        XCTAssertEqual(subject.initialPrice, Decimal(string: "70"))
        XCTAssertTrue(subject.seedComparisonBaseline())
        XCTAssertEqual(subject.initialPrice, Decimal(string: "100"))
        XCTAssertEqual(subject.initialCurrency, "USD")
    }

    func testSeedingNeverBadgesEvenWhenTheCheapestSellerIsBelowThreshold() {
        var subject = tracker([
            store("https://source.example/p", "100"),
            store("https://cheap.example/p", "50"),
            store("https://dear.example/p", "120"),
        ], threshold: 0.10)
        subject.seedComparisonBaseline()
        // Median 100, best 50 → a 50% "discount" that is really just the market.
        XCTAssertTrue(subject.isAlerting)
        XCTAssertNotNil(subject.alertAcknowledgedAt)
        XCTAssertFalse(subject.hasUnviewedAlert, "seeding must not float the row to the top")
    }

    func testSeedingIsANoOpForANonPositiveMedian() {
        var subject = tracker([store("https://a.example/p", "10")])
        let before = subject
        subject.seedComparisonBaseline(medianPrice: 0, currency: "USD")
        XCTAssertEqual(subject.initialPrice, before.initialPrice)
        XCTAssertNil(subject.alertAcknowledgedAt)
    }

    // MARK: - No notification on the first refresh after seeding

    private final class FakeStore: PriceTrackerPersisting {
        var items: [ReadingListItem]
        private(set) var bumped: [UUID] = []
        init(_ items: [ReadingListItem]) { self.items = items }
        func priceTrackersStalestFirst() -> [ReadingListItem] { items }
        func updatePriceTracker(_ tracker: PriceTracker, for itemID: UUID) -> ReadingListItem? {
            guard let index = items.firstIndex(where: { $0.id == itemID }) else { return nil }
            items[index].priceTracker = tracker
            return items[index]
        }
        func bump(_ itemID: UUID) { bumped.append(itemID) }
        func item(withID itemID: UUID) -> ReadingListItem? { items.first { $0.id == itemID } }
    }

    /// A price-drop notification comes only from `PriceRefreshOutcome
    /// .newlyAlerting`, a TRANSITION. A seeded tracker is already alerting
    /// before the first refresh runs, so the transition never happens — and the
    /// row is never bumped to the front of the deck either.
    func testFirstRefreshAfterSeedingIsNotNewlyAlerting() async {
        let sourceURL = "https://source.example/p"
        let cheapURL = "https://cheap.example/p"
        var subject = tracker([store(sourceURL, "100"), store(cheapURL, "50")], threshold: 0.10)
        subject.seedComparisonBaseline()

        var item = ReadingListItem(urlString: sourceURL)
        item.priceTracker = subject
        let fake = FakeStore([item])
        let fetcher = MockPriceFetcher()
        fetcher.priceByURL = [
            sourceURL: ProductPrice(amount: 100, currency: "USD"),
            cheapURL: ProductPrice(amount: 50, currency: "USD"),
        ]

        let outcome = await PriceRefresher(store: fake, priceFetcher: fetcher)
            .refreshTracker(subject, itemID: item.id)
        XCTAssertEqual(outcome?.isAlerting, true)
        XCTAssertEqual(outcome?.newlyAlerting, false, "seeding must not fire a price-drop alert")
        XCTAssertTrue(fake.bumped.isEmpty)
    }
}

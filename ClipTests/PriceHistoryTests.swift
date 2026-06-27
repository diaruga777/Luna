//
//  PriceHistoryTests.swift
//  ClipTests
//

import ClipModels
import XCTest
@testable import Clip

final class PriceHistoryTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private func day(_ n: Int) -> Date { Date(timeIntervalSinceReferenceDate: Double(n) * 86_400) }
    private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

    private func tracker(history: [PriceDaySnapshot], currency: String = "USD") -> PriceTracker {
        var t = PriceTracker(productName: "P", firstStoreURL: "https://a.com/p",
                             price: dec("100"), currency: currency)
        // Replace the single store's history.
        var store = t.stores[0]
        store.priceHistory = history
        t.upsertStore(store)
        return t
    }

    // MARK: - recordSample bucketing

    func testRecordSampleKeepsLowestPerDay() {
        var store = PriceTrackerStore(urlString: "https://a.com/p", lastPrice: nil, currency: "USD")
        let noon = day(10).addingTimeInterval(43_200)
        store.recordSample(price: dec("90"), currency: "USD", at: day(10), calendar: calendar)
        store.recordSample(price: dec("80"), currency: "USD", at: noon, calendar: calendar)   // lower same day
        store.recordSample(price: dec("85"), currency: "USD", at: noon, calendar: calendar)   // not lower
        store.recordSample(price: dec("70"), currency: "USD", at: day(11), calendar: calendar) // new day
        XCTAssertEqual(store.priceHistory.count, 2)
        XCTAssertEqual(store.priceHistory[0].lowestPrice, dec("80"))
        XCTAssertEqual(store.priceHistory[1].lowestPrice, dec("70"))
    }

    // MARK: - Migration

    func testOldStoreWithoutHistoryDecodesToEmpty() throws {
        let legacy = #"{"urlString":"https://a.com/p","currency":"USD","lastPrice":99}"#
        let store = try JSONDecoder().decode(PriceTrackerStore.self, from: Data(legacy.utf8))
        XCTAssertEqual(store.priceHistory, [])
        XCTAssertEqual(store.currency, "USD")
    }

    // MARK: - series + bucketing

    func testSeriesPerDayLowestAcrossStores() {
        var t = PriceTracker(productName: "P", firstStoreURL: "https://a.com/p",
                             price: dec("100"), currency: "USD")
        var a = t.stores[0]
        a.priceHistory = [PriceDaySnapshot(dayStart: day(1), lowestPrice: dec("90"), currency: "USD", fxRate: nil)]
        t.upsertStore(a)
        t.upsertStore(PriceTrackerStore(urlString: "https://b.com/p", lastPrice: nil, currency: "USD",
            priceHistory: [PriceDaySnapshot(dayStart: day(1), lowestPrice: dec("85"), currency: "USD", fxRate: nil)]))
        let series = PriceHistory.series(for: t, calendar: calendar)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series[0].price, dec("85"))
        XCTAssertEqual(series[0].storeURLString, "https://b.com/p")
    }

    func testBucketThresholds() {
        XCTAssertEqual(PriceHistory.bucket(forSpanDays: 30), .day)
        XCTAssertEqual(PriceHistory.bucket(forSpanDays: 120), .week)
        XCTAssertEqual(PriceHistory.bucket(forSpanDays: 600), .month)
        XCTAssertEqual(PriceHistory.bucket(forSpanDays: 5000), .year)
    }

    func testSeriesRebucketsToWeeklyLowOverLongSpan() {
        // ~100 days of daily samples → weekly buckets, lowest per week.
        var history: [PriceDaySnapshot] = []
        for n in 0..<100 {
            history.append(PriceDaySnapshot(
                dayStart: day(n), lowestPrice: dec("\(100 - n)"), currency: "USD", fxRate: nil))
        }
        let series = PriceHistory.series(for: tracker(history: history), calendar: calendar)
        XCTAssertLessThan(series.count, 100)       // collapsed into weeks
        XCTAssertGreaterThan(series.count, 10)
        // Daily prices decrease monotonically → each later week's low is lower, so the
        // weekly series is in strictly descending price order.
        XCTAssertEqual(series.map { $0.price }, series.map { $0.price }.sorted(by: >))
    }

    func testDistinctDayCount() {
        let t = tracker(history: [
            PriceDaySnapshot(dayStart: day(1), lowestPrice: dec("9"), currency: "USD", fxRate: nil),
            PriceDaySnapshot(dayStart: day(2), lowestPrice: dec("8"), currency: "USD", fxRate: nil),
        ])
        XCTAssertEqual(PriceHistory.distinctDayCount(t), 2)
        XCTAssertLessThan(PriceHistory.distinctDayCount(t), PriceHistory.minimumDaysForGraph)
    }
}

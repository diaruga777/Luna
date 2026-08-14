//
//  TrackedProductHistoryTests.swift
//  LunaTests
//

import LunaModels
import LunaPriceCompare
import XCTest

/// Pins the SQL-backed projection to the retired history index's retention
/// contract. Both Safari matching paths construct this projection, so neither
/// can accidentally expose a different history window.
final class TrackedProductHistoryTests: XCTestCase {

    func testProjectionKeepsOnlyTheShared365DayWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!

        func date(daysBeforeNow days: Int) -> Date {
            utcCalendar.date(byAdding: .day, value: -days, to: now)!
        }

        let store = PriceTrackerStore(
            urlString: "https://shop.example/p/1", lastPrice: nil, currency: "USD",
            priceHistory: [
                PriceDaySnapshot(
                    dayStart: date(daysBeforeNow: PriceHistoryIndexEntry.maxPointAgeDays + 1),
                    lowestPrice: 99, currency: "USD", fxRate: nil),
                PriceDaySnapshot(
                    dayStart: date(daysBeforeNow: PriceHistoryIndexEntry.maxPointAgeDays),
                    lowestPrice: 60, currency: "USD", fxRate: nil),
                PriceDaySnapshot(
                    dayStart: date(daysBeforeNow: 10),
                    lowestPrice: 45, currency: "USD", fxRate: nil),
            ])
        let tracker = PriceTracker(productName: "Widget", stores: [store])

        let entry = PriceHistoryIndexEntry(tracker: tracker, now: now)

        XCTAssertEqual(PriceHistoryIndexEntry.maxPointAgeDays, 365)
        XCTAssertEqual(entry.stores[0].points.map(\.price), ["60", "45"])
    }
}

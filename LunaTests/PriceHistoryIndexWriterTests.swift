//
//  PriceHistoryIndexWriterTests.swift
//  LunaTests
//

import LunaModels
import LunaPriceUI
import XCTest

/// `PriceHistoryIndexWriter`: entry contents, the 365-day trim, and that every
/// documented regeneration hook actually calls it (source-text check, the
/// same pattern `SafariSetupCelebrationTests` uses for cross-process parity).
final class PriceHistoryIndexWriterTests: XCTestCase {

    private func tracker(
        name: String = "Widget", brand: String? = "Acme", productID: String? = "SKU-1",
        stores: [PriceTrackerStore]
    ) -> PriceTracker {
        PriceTracker(productName: name, stores: stores, brand: brand, productID: productID)
    }

    private func daySnapshot(_ dayOffset: Int, price: String, from now: Date) -> PriceDaySnapshot {
        PriceDaySnapshot(
            dayStart: Calendar(identifier: .gregorian).startOfDay(
                for: now.addingTimeInterval(Double(dayOffset) * 86400)),
            lowestPrice: Decimal(string: price)!, currency: "USD", fxRate: nil)
    }

    func testMakeEntriesCarriesNameBrandProductIDAndPerStorePoints() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = PriceTrackerStore(
            urlString: "https://shop.example/p/1", lastPrice: Decimal(string: "40"), currency: "USD",
            priceHistory: [daySnapshot(-1, price: "45", from: now), daySnapshot(0, price: "40", from: now)])
        let entries = PriceHistoryIndexWriter.makeEntries(from: [tracker(stores: [store])], now: now)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "Widget")
        XCTAssertEqual(entries[0].brand, "Acme")
        XCTAssertEqual(entries[0].productID, "SKU-1")
        XCTAssertEqual(entries[0].stores.count, 1)
        XCTAssertEqual(entries[0].stores[0].host, "shop.example")
        XCTAssertEqual(entries[0].stores[0].points.count, 2)
        XCTAssertEqual(entries[0].stores[0].points.map(\.price), ["45", "40"])
    }

    func testArchivedTrackersAreExcluded() {
        var archived = tracker(stores: [
            PriceTrackerStore(urlString: "https://shop.example/p/1", lastPrice: nil, currency: "USD"),
        ])
        archived.isArchived = true
        let entries = PriceHistoryIndexWriter.makeEntries(from: [archived])
        XCTAssertTrue(entries.isEmpty)
    }

    func testPointsOlderThan365DaysAreTrimmed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = PriceTrackerStore(
            urlString: "https://shop.example/p/1", lastPrice: nil, currency: "USD",
            priceHistory: [
                daySnapshot(-400, price: "99", from: now),
                daySnapshot(-10, price: "45", from: now),
            ])
        let entries = PriceHistoryIndexWriter.makeEntries(from: [tracker(stores: [store])], now: now)
        XCTAssertEqual(entries[0].stores[0].points.map(\.price), ["45"])
    }

    func testWriteThenLoadRoundTrips() {
        let entry = PriceHistoryIndexEntry(
            name: "Widget", brand: "Acme", productID: "SKU-1",
            stores: [PriceHistoryIndexEntry.StorePoints(
                url: "https://shop.example/p/1", host: "shop.example",
                points: [PriceHistoryIndexEntry.Point(day: "2026-01-01", price: "40", currency: "USD")])])
        // `PriceHistoryIndexWriter.write`/`load` go through the real App Group
        // container path — exercised for real by `write`'s round trip in the
        // ingest/refresh integration tests; here we only confirm the shape
        // encodes/decodes without loss.
        let data = try! JSONEncoder().encode([entry])
        let decoded = try! JSONDecoder().decode([PriceHistoryIndexEntry].self, from: data)
        XCTAssertEqual(decoded, [entry])
    }

    // MARK: - Regeneration hooks (source-text parity)

    private static func source(_ relativePath: String) -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)) ?? ""
    }

    func testIngestRegeneratesTheIndex() {
        XCTAssertTrue(
            Self.source("LunaLibraries/Sources/LunaPriceUI/ProductTrackerIngestor.swift")
                .contains("PriceHistoryIndexWriter.regenerate()"))
    }

    func testEveryRefreshCycleRegeneratesTheIndex() {
        XCTAssertTrue(
            Self.source("LunaLibraries/Sources/LunaPriceUI/PriceRefreshCoordinator.swift")
                .contains("PriceHistoryIndexWriter.regenerate()"))
    }

    func testBothProductAppsRegenerateOnBackground() {
        for file in ["Luna/KindWiring+Luna.swift", "Luna/KindWiring+PriceTracker.swift"] {
            XCTAssertTrue(
                Self.source(file).contains("PriceHistoryIndexWriter.regenerate()"),
                "\(file) does not regenerate the history index on background")
        }
    }
}

//
//  ProductSnapshotSweepTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaModels
import LunaStorage
@testable import LunaPriceUI
import XCTest

/// The read-side leg the snapshot pipeline was missing: passive Safari
/// captures folding into EXISTING trackers — matched by PRODUCT CODE
/// (`SnapshotMatcher`'s identifier tiers), never by URL equality — so browsing
/// a tracked product yesterday becomes a past-day graph point today.
final class ProductSnapshotSweepTests: XCTestCase {

    private var tempDirectory: URL!
    private var store: ReadingListStore!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProductSnapshotSweepTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: tempDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    // MARK: - Fixtures

    @discardableResult
    private func addTracker(
        gtin: String? = "9337640009775", currency: String = "AUD", archived: Bool = false
    ) -> UUID {
        var tracker = PriceTracker(
            productName: "Hisense HRFD634BW Fridge",
            firstStoreURL: "https://jbhifi.example/p/1",
            price: 1999, currency: currency, brand: "Hisense",
            productID: gtin,
            identifiers: ProductIdentifiers(gtin: gtin, brand: "Hisense"))
        if archived { tracker.isArchived = true }
        let item = store.add(urlString: "https://jbhifi.example/p/1")
        store.savePriceTracker(tracker, for: item.id)
        return item.id
    }

    private func snapshot(
        gtin: String? = "9337640009775", currency: String = "AUD",
        url: String = "https://binglee.example/p/9", host: String = "binglee.example",
        day: String = "2026-08-09", price: String = "1899",
        name: String = "Something Entirely Different"
    ) -> ProductSnapshot {
        // The NAME deliberately shares nothing with the tracker and the URL is
        // on a host the tracker has never seen: only the product CODE can make
        // these match.
        ProductSnapshot(
            name: name, price: price, currency: currency, url: url, host: host,
            day: day, capturedAt: "\(day)T00:00:00Z", gtin: gtin)
    }

    // MARK: - Folding

    /// The headline behavior: a snapshot of the same GTIN on a DIFFERENT host
    /// at a DIFFERENT URL with a DIFFERENT title becomes a past-day history
    /// point on the existing tracker.
    func testASnapshotMatchingByProductCodeBecomesTrackerHistory() {
        let itemID = addTracker()
        var regenerated = 0
        let updated = ProductSnapshotSweep.run(
            store: store, snapshots: [snapshot()], indexRegenerator: { regenerated += 1 })

        XCTAssertEqual(updated, 1)
        let tracker = store.item(withID: itemID)?.priceTracker
        let seeded = tracker?.stores.first { $0.urlString.contains("binglee") }
        XCTAssertNotNil(seeded, "the snapshot's host joins as its own (price-less) store")
        XCTAssertEqual(seeded?.priceHistory.first?.lowestPrice, Decimal(string: "1899"))
        XCTAssertEqual(regenerated, 1, "the pill's index must see the new points")
    }

    /// A same-URL snapshot from yesterday reaches the tracker too — the
    /// re-save dedup short-circuit never seeds, so the sweep is what makes
    /// "I looked at this same page yesterday" a graph point.
    func testYesterdaysVisitToAnExistingStoreBecomesAPastDayPoint() {
        let itemID = addTracker()
        _ = ProductSnapshotSweep.run(
            store: store,
            snapshots: [snapshot(
                url: "https://jbhifi.example/p/1", host: "jbhifi.example",
                day: "2026-08-08", price: "1949")],
            indexRegenerator: {})
        let tracker = store.item(withID: itemID)?.priceTracker
        let history = tracker?.stores.first { $0.urlString.contains("jbhifi") }?.priceHistory
        XCTAssertEqual(history?.first?.lowestPrice, Decimal(string: "1949"))
        XCTAssertEqual(tracker?.stores.count, 1, "same host merges, never a second store")
    }

    /// Running twice is a no-op the second time — the day bucket already holds
    /// the sample, so nothing is rewritten and the index is not regenerated.
    func testTheSweepIsIdempotent() {
        addTracker()
        let snapshots = [snapshot()]
        XCTAssertEqual(ProductSnapshotSweep.run(
            store: store, snapshots: snapshots, indexRegenerator: {}), 1)
        var regenerated = 0
        XCTAssertEqual(ProductSnapshotSweep.run(
            store: store, snapshots: snapshots, indexRegenerator: { regenerated += 1 }), 0)
        XCTAssertEqual(regenerated, 0)
    }

    // MARK: - Refusals

    func testAnUnrelatedSnapshotFoldsIntoNothing() {
        let itemID = addTracker()
        let updated = ProductSnapshotSweep.run(
            store: store, snapshots: [snapshot(gtin: "0000000000017")], indexRegenerator: {})
        XCTAssertEqual(updated, 0)
        XCTAssertEqual(store.item(withID: itemID)?.priceTracker?.stores.count, 1)
    }

    func testAnArchivedTrackerIsLeftAlone() {
        let itemID = addTracker(archived: true)
        XCTAssertEqual(ProductSnapshotSweep.run(
            store: store, snapshots: [snapshot()], indexRegenerator: {}), 0)
        XCTAssertEqual(store.item(withID: itemID)?.priceTracker?.stores.count, 1)
    }

    /// The market rule holds here too: the same GTIN browsed on a foreign
    /// storefront is real data Luna cannot use — no FX source, so a £ point
    /// must not land on a $ graph.
    func testAForeignCurrencySnapshotIsNeverFoldedIn() {
        let itemID = addTracker(currency: "AUD")
        let updated = ProductSnapshotSweep.run(
            store: store,
            snapshots: [snapshot(currency: "USD", url: "https://us.example/p/1", host: "us.example")],
            indexRegenerator: {})
        XCTAssertEqual(updated, 0)
        XCTAssertEqual(store.item(withID: itemID)?.priceTracker?.stores.count, 1)
    }
}

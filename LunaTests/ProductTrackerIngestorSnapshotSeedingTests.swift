//
//  ProductTrackerIngestorSnapshotSeedingTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaModels
import LunaPriceCompare
import LunaStorage
@testable import LunaPriceUI
import XCTest

/// `ProductTrackerIngestor`'s Feature 1 seeding: matched snapshots become a
/// new store per new host, merge into an existing same-host store, day-bucket
/// with lowest-wins, never touch `initialPrice`, and kick a single-tracker
/// refresh (via the injected spy seam) once persisted.
final class ProductTrackerIngestorSnapshotSeedingTests: XCTestCase {

    private var tempDirectory: URL!
    private var snapshotDirectory: URL?
    private var store: ReadingListStore!
    private var ingestor: ProductTrackerIngestor!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProductTrackerIngestorSnapshotSeedingTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: tempDirectory)
        ingestor = ProductTrackerIngestor()
        ingestor.indexRegenerator = {}
        // Never the real App Group store: a test must not read (or write) the
        // observations a developer's own browsing left behind.
        ingestor.snapshotStore = .temporary(directory: &snapshotDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        if let snapshotDirectory { try? FileManager.default.removeItem(at: snapshotDirectory) }
        super.tearDown()
    }

    /// Seeds the shared-store the ingestor reads at save time.
    private func seedSnapshots(_ snapshots: [ProductSnapshot]) {
        ingestor.snapshotStore = .temporary(snapshots, directory: &snapshotDirectory)
    }

    private func snapshot(
        price: String, day: String, url: String, gtin: String? = "0012345678905",
        name: String = "Acme Widget"
    ) -> ProductSnapshot {
        ProductSnapshot(
            name: name, price: price, currency: "USD", url: url,
            host: URL(string: url)!.host!, day: day, capturedAt: "\(day)T00:00:00Z", gtin: gtin)
    }

    private func product(gtin: String? = "0012345678905") -> ProductInfo {
        ProductInfo(
            name: "Acme Widget", priceAmount: Decimal(string: "60")!, priceCurrency: "USD",
            imageURL: nil, brand: nil, productID: gtin)
    }

    /// Awaits the fire-and-forget post-seed refresh Task by fulfilling an
    /// expectation from inside the injected `refreshRunner`.
    private func expectRefresh(returning outcome: PriceRefreshOutcome? = nil) -> (XCTestExpectation, () -> Void) {
        let expectation = expectation(description: "refreshRunner invoked")
        var capturedItemID: UUID?
        ingestor.refreshRunner = { itemID in
            capturedItemID = itemID
            expectation.fulfill()
            return outcome
        }
        return (expectation, { XCTAssertNotNil(capturedItemID) })
    }

    // MARK: - New tracker

    func testNewTrackerSeedsAStorePerNewHostFromMatchedSnapshots() async {
        let itemA = store.add(urlString: "https://shop-a.example/p/1")
        let itemB = store.add(urlString: "https://shop-b.example/p/1")
        seedSnapshots(
            [snapshot(price: "45", day: "2026-01-05", url: "https://shop-a.example/p/1"),
             snapshot(price: "40", day: "2026-01-06", url: "https://shop-b.example/other")])
        let (expectation, verify) = expectRefresh()

        await ingestor.ingest(itemA, url: URL(string: "https://shop-a.example/p/1")!,
                              product: product(), store: store)
        await fulfillment(of: [expectation], timeout: 5)
        verify()

        let saved = store.item(withID: itemA.id)?.priceTracker
        XCTAssertEqual(saved?.stores.count, 2, "one store per matched host")
        XCTAssertTrue(saved?.stores.contains { $0.urlString.contains("shop-b.example") } ?? false)
        // initialPrice is the CREATION-time baseline (the passed product's
        // price) and must never move because of history seeding.
        XCTAssertEqual(saved?.initialPrice, Decimal(string: "60"))
        XCTAssertFalse(PriceHistory.series(for: saved!).isEmpty, "seeded history must feed the graph")

        // Clean up the untouched placeholder item created for itemB's URL.
        _ = itemB
    }

    func testDayBucketedHistoryTakesTheLowestPricePerDay() async {
        let item = store.add(urlString: "https://shop-a.example/p/1")
        seedSnapshots(
            [snapshot(price: "50", day: "2026-01-05", url: "https://shop-a.example/other-a"),
             snapshot(price: "42", day: "2026-01-05", url: "https://shop-a.example/other-b")])
        let (expectation, _) = expectRefresh()
        await ingestor.ingest(item, url: URL(string: "https://shop-a.example/p/1")!,
                              product: product(), store: store)
        await fulfillment(of: [expectation], timeout: 5)

        let saved = store.item(withID: item.id)?.priceTracker
        let hostStore = saved?.stores.first { $0.urlString.contains("shop-a.example") }
        XCTAssertEqual(hostStore?.priceHistory.count, 1, "both snapshots land in the SAME day bucket")
        XCTAssertEqual(hostStore?.priceHistory.first?.lowestPrice, Decimal(string: "42"))
    }

    func testUnmatchedSnapshotsDoNotSeedAnything() async {
        let item = store.add(urlString: "https://shop-a.example/p/1")
        seedSnapshots(
            [snapshot(price: "10", day: "2026-01-01", url: "https://unrelated.example/p",
                           gtin: "9999999999999", name: "Something Totally Unrelated")])
        let (expectation, _) = expectRefresh()
        await ingestor.ingest(item, url: URL(string: "https://shop-a.example/p/1")!,
                              product: product(), store: store)
        await fulfillment(of: [expectation], timeout: 5)

        let saved = store.item(withID: item.id)?.priceTracker
        XCTAssertEqual(saved?.stores.count, 1)
        XCTAssertTrue(saved?.stores.first?.priceHistory.isEmpty ?? false)
    }

    // MARK: - Merge into an existing tracker

    func testMergingIntoAnExistingTrackerSeedsHistoryIntoTheSameHostStoreOnly() async {
        // An existing tracker already has a store at shop-a; the new save adds
        // shop-c. A snapshot for shop-a must MERGE into the existing store
        // (no second store for the same host); a snapshot for a brand-new host
        // (shop-d) adds one more store.
        let existingTracker = PriceTracker(
            productName: "Acme Widget", firstStoreURL: "https://shop-a.example/p/1",
            price: Decimal(string: "55")!, currency: "USD", productID: "0012345678905")
        let existingItem = store.add(urlString: "https://shop-a.example/p/1")
        store.savePriceTracker(existingTracker, for: existingItem.id)

        let newItem = store.add(urlString: "https://shop-c.example/p/1")
        seedSnapshots(
            [snapshot(price: "48", day: "2026-01-05", url: "https://shop-a.example/other"),
             snapshot(price: "39", day: "2026-01-06", url: "https://shop-d.example/other")])
        let (expectation, _) = expectRefresh()
        await ingestor.ingest(newItem, url: URL(string: "https://shop-c.example/p/1")!,
                              product: product(), store: store)
        await fulfillment(of: [expectation], timeout: 5)

        // The placeholder new-save item was folded into the existing tracker.
        XCTAssertNil(store.item(withID: newItem.id))
        let merged = store.item(withID: existingItem.id)?.priceTracker
        let hostsWithHistory = merged?.stores.filter { !$0.priceHistory.isEmpty }.map {
            URL(string: $0.urlString)?.host
        }
        XCTAssertEqual(Set(hostsWithHistory ?? []), Set(["shop-a.example", "shop-d.example"]))
        XCTAssertEqual(
            merged?.stores.filter { URL(string: $0.urlString)?.host == "shop-a.example" }.count, 1,
            "seeding must never create a second store for a host the tracker already has")
        // The original creation-time baseline must be untouched by seeding.
        XCTAssertEqual(merged?.initialPrice, Decimal(string: "55"))
    }
}

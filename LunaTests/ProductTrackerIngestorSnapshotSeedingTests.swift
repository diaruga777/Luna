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

/// Test doubles for the product-save seams, shared by every product suite in
/// the bundle: a fan-out start that records instead of running, a refresh that
/// answers a fixture, and the two no-op halves of `finishSeeding`.
final class RecordingComparisonStarter: SellerComparisonStarting {
    /// Every kick, in order.
    private(set) var kicks: [(itemID: UUID, sourceURL: URL)] = []

    func startComparison(itemID: UUID, sourceURL: URL, store: SavesStore) {
        kicks.append((itemID, sourceURL))
    }
}

/// A start that must never happen — the assertion IS the double.
struct ForbiddenComparisonStarter: SellerComparisonStarting {
    let reason: String

    func startComparison(itemID: UUID, sourceURL: URL, store: SavesStore) {
        XCTFail(reason)
    }
}

/// A refresh that records the tracker it was asked for and answers `outcome`.
final class StubTrackerRefresher: SingleTrackerRefreshing {
    var outcome: PriceRefreshOutcome?
    private(set) var refreshedItemIDs: [UUID] = []
    /// Called on each refresh, so a test can fulfill an expectation from inside
    /// the fire-and-forget Task that drives it.
    var onRefresh: (() -> Void)?

    init(outcome: PriceRefreshOutcome? = nil) { self.outcome = outcome }

    func refresh(itemID: UUID) async -> PriceRefreshOutcome? {
        refreshedItemIDs.append(itemID)
        onRefresh?()
        return outcome
    }
}

/// The index regeneration a test does not want to run against the real file.
struct SilentIndexRegenerator: PriceHistoryIndexRegenerating {
    func regenerate() {}
}

/// Artwork that answers `data` for any page (nil ⇒ no image at all) and records
/// what it was asked for.
final class StubArtworkLoader: ProductArtworkLoading, @unchecked Sendable {
    private let data: Data?
    private(set) var requestedPrimaryURLs: [URL?] = []
    /// Called on each load, so a test can await the fire-and-forget backfill.
    var onLoad: (() -> Void)?

    init(data: Data?) { self.data = data }

    func artworkData(primaryURL: URL?, pageURL: URL) async -> Data? {
        requestedPrimaryURLs.append(primaryURL)
        onLoad?()
        return data
    }
}

/// `ProductTrackerIngestor`'s Feature 1 seeding: matched snapshots become a
/// new store per new host, merge into an existing same-host store, day-bucket
/// with lowest-wins, never touch `initialPrice`, and kick a single-tracker
/// refresh (via the injected spy seam) once persisted.
final class ProductTrackerIngestorSnapshotSeedingTests: XCTestCase {

    private var tempDirectory: URL!
    private var snapshotDirectory: URL?
    private var store: SavesStore!
    private var ingestor: ProductTrackerIngestor!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProductTrackerIngestorSnapshotSeedingTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = SavesStore(containerURL: tempDirectory)
        ingestor = ProductTrackerIngestor()
        ingestor.indexRegenerator = SilentIndexRegenerator()
        // This suite is about SEEDING, so the fan-out is stubbed out at the
        // ingestor's own seam rather than left to whatever a previously-run
        // class left in `SellerComparisonRunner.installed`. With it live, a
        // merge kicks a comparison that completes empty and re-bases
        // `initialPrice` onto the store median — a real behaviour, asserted by
        // `SellerComparisonTests`, and pure noise here.
        ingestor.comparisonStarter = RecordingComparisonStarter()
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
        name: String = "Acme Widget", brand: String? = nil
    ) -> ProductSnapshot {
        ProductSnapshot(
            name: name, price: price, currency: "USD", url: url,
            host: URL(string: url)!.host!, day: day, capturedAt: "\(day)T12:00:00Z", gtin: gtin,
            brand: brand)
    }

    private func product(
        gtin: String? = "0012345678905", name: String = "Acme Widget", brand: String? = nil
    ) -> ProductInfo {
        ProductInfo(
            name: name, priceAmount: Decimal(string: "60")!, priceCurrency: "USD",
            imageURL: nil, brand: brand, productID: gtin)
    }

    /// Awaits the fire-and-forget post-seed refresh Task by fulfilling an
    /// expectation from inside the installed refresher.
    private func expectRefresh(returning outcome: PriceRefreshOutcome? = nil) -> (XCTestExpectation, () -> Void) {
        let expectation = expectation(description: "the tracker refresh ran")
        let refresher = StubTrackerRefresher(outcome: outcome)
        refresher.onRefresh = { expectation.fulfill() }
        ingestor.refresher = refresher
        return (expectation, { XCTAssertFalse(refresher.refreshedItemIDs.isEmpty) })
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

    /// The reported failure, through the real store: yesterday's observation
    /// was filed by the Safari extension under the page's CANONICAL url, the
    /// page declares no identifier, and today's save is keyed by the url the
    /// user actually saved. Nothing but the name connects them — and the point
    /// must still reach the graph, dated the day it was observed.
    func testAnIdentifierLessObservationFiledUnderTheCanonicalURLStillSeedsTheSave() async {
        let item = store.add(urlString: "https://shop-a.example/p/kettle?variant=blue")
        seedSnapshots([snapshot(
            price: "45", day: "2026-01-05", url: "https://shop-a.example/p/kettle",
            gtin: nil, name: "Kestrel 6L Stainless Kettle", brand: "Kestrel")])
        let (expectation, _) = expectRefresh()

        await ingestor.ingest(
            item, url: URL(string: "https://shop-a.example/p/kettle?variant=blue")!,
            product: product(gtin: nil, name: "Kestrel 6L Stainless Kettle", brand: "Kestrel"),
            store: store)
        await fulfillment(of: [expectation], timeout: 5)

        let saved = store.item(withID: item.id)?.priceTracker
        let points = PriceHistory.dailySeries(for: saved!)
        XCTAssertEqual(points.map(\.price), [Decimal(string: "45")])
        XCTAssertEqual(
            points.first.map { Calendar.current.startOfDay(for: $0.date) },
            Calendar.current.startOfDay(
                for: ISO8601DateFormatter().date(from: "2026-01-05T12:00:00Z")!),
            "the point belongs on the day the observation was made")
    }

    /// An observation is a price AT a retailer, so the seller it came from is a
    /// row on the tracker with that price on it — not an invisible contributor
    /// to the graph.
    func testASeededSellerCarriesTheObservedPriceAndDate() async {
        let item = store.add(urlString: "https://shop-a.example/p/1")
        seedSnapshots(
            [snapshot(price: "49", day: "2026-01-05", url: "https://shop-b.example/p/9"),
             snapshot(price: "44", day: "2026-01-06", url: "https://shop-b.example/p/9")])
        let (expectation, _) = expectRefresh()

        await ingestor.ingest(item, url: URL(string: "https://shop-a.example/p/1")!,
                              product: product(), store: store)
        await fulfillment(of: [expectation], timeout: 5)

        let saved = store.item(withID: item.id)?.priceTracker
        let seeded = saved?.stores.first { $0.urlString.contains("shop-b.example") }
        XCTAssertEqual(seeded?.lastPrice, Decimal(string: "44"), "the latest observation is the row's price")
        XCTAssertEqual(seeded?.currency, "USD")
        XCTAssertNotNil(seeded?.lastRefreshed, "a row with a price must say when it was seen")
    }

    /// The recovery path for a wrong match: the removed seller's points leave
    /// the graph with it, and a LATER save that matches the same observations
    /// all over again must not put them back.
    func testARemovedSellerStaysRemovedAcrossALaterSave() async {
        let item = store.add(urlString: "https://shop-a.example/p/1")
        seedSnapshots(
            [snapshot(price: "49", day: "2026-01-05", url: "https://shop-b.example/p/9")])
        let (firstRefresh, _) = expectRefresh()
        await ingestor.ingest(item, url: URL(string: "https://shop-a.example/p/1")!,
                              product: product(), store: store)
        await fulfillment(of: [firstRefresh], timeout: 5)

        var tracker = store.item(withID: item.id)!.priceTracker!
        let seededURL = tracker.stores.first { $0.urlString.contains("shop-b.example") }!.urlString
        XCTAssertTrue(tracker.removeStore(urlString: seededURL))
        store.updatePriceTracker(tracker, for: item.id)
        XCTAssertFalse(
            PriceHistory.dailySeries(for: store.item(withID: item.id)!.priceTracker!)
                .contains { $0.price == Decimal(string: "49") },
            "removing the seller takes its points off the graph")

        // A second save of the same product, with the same observation still in
        // the store — the merge branch, which seeds history all over again.
        let again = store.add(urlString: "https://shop-a.example/p/1-again")
        let (secondRefresh, _) = expectRefresh()
        await ingestor.ingest(again, url: URL(string: "https://shop-a.example/p/1-again")!,
                              product: product(), store: store)
        await fulfillment(of: [secondRefresh], timeout: 5)

        let after = store.item(withID: item.id)!.priceTracker!
        XCTAssertFalse(
            after.stores.contains { $0.urlString.contains("shop-b.example") },
            "a rejected seller must not be re-attached by a later save")
        XCTAssertFalse(
            PriceHistory.dailySeries(for: after).contains { $0.price == Decimal(string: "49") },
            "nor may its points come back on their own")
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

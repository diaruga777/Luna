//
//  ProductTrackerMergeTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaModels
import LunaPriceCompare
import LunaStorage
@testable import LunaPriceUI
import XCTest

/// The merge-or-create decision shared by the in-app new-tracker path
/// (`ProductTrackerIngestor.ingest`) and the extension's immediate-editor
/// path (`ExtensionProductPresenter.presentPriceEditor`). Before this was
/// shared, only the app path consulted `ProductMatcher.bestMatch` or seeded
/// snapshot history — a share-sheet save of an already-tracked product
/// created a duplicate tracker instead of merging, even when both pages
/// declared the SAME GTIN.
final class ProductTrackerMergeTests: XCTestCase {

    private var tempDirectory: URL!
    private var snapshotDirectory: URL?
    private var store: ReadingListStore!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProductTrackerMergeTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: tempDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        if let snapshotDirectory { try? FileManager.default.removeItem(at: snapshotDirectory) }
        super.tearDown()
    }

    /// A throwaway snapshot store, so a merge test never reads the real
    /// App Group container.
    private func snapshotStore(_ snapshots: [ProductSnapshot] = []) -> ProductSnapshotStore {
        .temporary(snapshots, directory: &snapshotDirectory)
    }

    private func product(
        name: String = "Hisense HRFD634BW Fridge", gtin: String? = nil, mpn: String? = nil,
        brand: String? = "Hisense"
    ) -> ProductInfo {
        ProductInfo(
            name: name, priceAmount: 1999, priceCurrency: "AUD", imageURL: nil, brand: brand,
            productID: gtin, identifiers: ProductIdentifiers(gtin: gtin, mpn: mpn, brand: brand))
    }

    // MARK: - No match

    func testNoExistingTrackerYieldsNewTracker() {
        let placeholder = store.add(urlString: "https://a.example/p/1")
        let outcome = ProductTrackerMerge.mergeIfPossible(
            product: product(), url: URL(string: "https://a.example/p/1")!,
            excludingItemID: placeholder.id, store: store,
            comparisonStarter: { _, _, _ in XCTFail("must not start a comparison for a new tracker") },
            snapshotStore: snapshotStore())
        XCTAssertEqual(outcome, .newTracker)
    }

    // MARK: - Merging

    func testAMatchingGTINMergesAndUnionsTheStoreURL() {
        let existing = PriceTracker(
            productName: "Hisense HRFD634BW Fridge", firstStoreURL: "https://jbhifi.example/p/1",
            price: 1999, currency: "AUD", brand: "Hisense",
            identifiers: ProductIdentifiers(gtin: "9337640009775", brand: "Hisense"))
        let existingItem = store.add(urlString: "https://jbhifi.example/p/1")
        store.savePriceTracker(existing, for: existingItem.id)

        let placeholder = store.add(urlString: "https://binglee.example/p/1")
        let outcome = ProductTrackerMerge.mergeIfPossible(
            product: product(gtin: "9337640009775"), url: URL(string: "https://binglee.example/p/1")!,
            excludingItemID: placeholder.id, store: store,
            comparisonStarter: { _, _, _ in }, snapshotStore: snapshotStore())

        guard case let .merged(itemID, highlighted) = outcome else {
            return XCTFail("expected a merge, got \(outcome)")
        }
        XCTAssertEqual(itemID, existingItem.id)
        XCTAssertEqual(highlighted, "https://binglee.example/p/1")
        let merged = store.item(withID: existingItem.id)?.priceTracker
        XCTAssertEqual(
            Set(merged?.stores.map(\.urlString) ?? []),
            ["https://jbhifi.example/p/1", "https://binglee.example/p/1"])
    }

    /// The caller's own placeholder item is excluded from the candidate pool
    /// — merging into itself is not a merge.
    func testTheCallersOwnPlaceholderIsNeverAMergeTarget() {
        let onlyItem = store.add(urlString: "https://a.example/p/1")
        store.savePriceTracker(
            PriceTracker(
                productName: "Hisense HRFD634BW Fridge", firstStoreURL: "https://a.example/p/1",
                price: 1999, currency: "AUD",
                identifiers: ProductIdentifiers(gtin: "9337640009775")),
            for: onlyItem.id)

        let outcome = ProductTrackerMerge.mergeIfPossible(
            product: product(gtin: "9337640009775"), url: URL(string: "https://a.example/p/1")!,
            excludingItemID: onlyItem.id, store: store,
            comparisonStarter: { _, _, _ in }, snapshotStore: snapshotStore())
        XCTAssertEqual(outcome, .newTracker)
    }

    /// Merging unions the candidate's keyed identifiers into the matched
    /// tracker's empty slots — a tracker created before `ProductIdentifiers`
    /// existed gains a GTIN from the save that merged into it.
    func testMergingFillsEmptyIdentifierSlotsOnTheMatchedTracker() {
        let existing = PriceTracker(
            productName: "Hisense HRFD634BW Fridge", firstStoreURL: "https://jbhifi.example/p/1",
            price: 1999, currency: "AUD", brand: "Hisense")
        XCTAssertTrue(existing.identifiers.isEmpty, "precondition: no identifiers yet")
        let existingItem = store.add(urlString: "https://jbhifi.example/p/1")
        store.savePriceTracker(existing, for: existingItem.id)

        let placeholder = store.add(urlString: "https://binglee.example/p/1")
        _ = ProductTrackerMerge.mergeIfPossible(
            product: product(name: "Hisense HRFD634BW Fridge", mpn: "HRFD634BW", brand: "Hisense"),
            url: URL(string: "https://binglee.example/p/1")!,
            excludingItemID: placeholder.id, store: store,
            comparisonStarter: { _, _, _ in }, snapshotStore: snapshotStore())

        let merged = store.item(withID: existingItem.id)?.priceTracker
        XCTAssertEqual(merged?.identifiers.mpn, "HRFD634BW")
    }

    // MARK: - Fix 8: kicking a comparison on merge

    /// A merge target that has never been compared and holds fewer than two
    /// stores kicks a comparison — this is what makes a repeat save of an
    /// Amazon-style single-store product actually attempt discovery.
    func testMergingIntoASellerlessNeverComparedTrackerKicksAComparison() {
        let existing = PriceTracker(
            productName: "Widget", firstStoreURL: "https://a.example/p/1", price: 10, currency: "USD",
            identifiers: ProductIdentifiers(gtin: "1111111111111"))
        let existingItem = store.add(urlString: "https://a.example/p/1")
        store.savePriceTracker(existing, for: existingItem.id)

        let placeholder = store.add(urlString: "https://b.example/p/1")
        var kicked: (itemID: UUID, url: URL)?
        _ = ProductTrackerMerge.mergeIfPossible(
            product: product(name: "Widget", gtin: "1111111111111"),
            url: URL(string: "https://b.example/p/1")!,
            excludingItemID: placeholder.id, store: store,
            comparisonStarter: { itemID, url, _ in kicked = (itemID, url) }, snapshotStore: snapshotStore())

        XCTAssertEqual(kicked?.itemID, existingItem.id)
        XCTAssertEqual(kicked?.url.absoluteString, "https://b.example/p/1")
    }

    /// A tracker that already holds 2+ stores has already been through (or
    /// is past the point of needing) a fan-out — the merge path stays quiet.
    func testMergingIntoATrackerWithTwoOrMoreStoresDoesNotKickAComparison() {
        var existing = PriceTracker(
            productName: "Widget", firstStoreURL: "https://a.example/p/1", price: 10, currency: "USD",
            identifiers: ProductIdentifiers(gtin: "1111111111111"))
        existing.upsertStore(PriceTrackerStore(urlString: "https://c.example/p/1", lastPrice: 9, currency: "USD"))
        let existingItem = store.add(urlString: "https://a.example/p/1")
        store.savePriceTracker(existing, for: existingItem.id)

        let placeholder = store.add(urlString: "https://b.example/p/1")
        _ = ProductTrackerMerge.mergeIfPossible(
            product: product(name: "Widget", gtin: "1111111111111"),
            url: URL(string: "https://b.example/p/1")!,
            excludingItemID: placeholder.id, store: store,
            comparisonStarter: { _, _, _ in XCTFail("must not kick a comparison") }, snapshotStore: snapshotStore())
    }

    /// A tracker already mid-fan-out (a pending marker) is not double-kicked.
    func testMergingIntoATrackerWithAPendingComparisonDoesNotKickAnother() {
        var existing = PriceTracker(
            productName: "Widget", firstStoreURL: "https://a.example/p/1", price: 10, currency: "USD",
            identifiers: ProductIdentifiers(gtin: "1111111111111"))
        existing.beginPendingComparison(sourceURLString: "https://a.example/p/1", at: Date())
        let existingItem = store.add(urlString: "https://a.example/p/1")
        store.savePriceTracker(existing, for: existingItem.id)

        let placeholder = store.add(urlString: "https://b.example/p/1")
        _ = ProductTrackerMerge.mergeIfPossible(
            product: product(name: "Widget", gtin: "1111111111111"),
            url: URL(string: "https://b.example/p/1")!,
            excludingItemID: placeholder.id, store: store,
            comparisonStarter: { _, _, _ in XCTFail("must not kick a second comparison") }, snapshotStore: snapshotStore())
    }

    // MARK: - Snapshot seeding on merge (Fix 7)

    /// A merge seeds history from a matching snapshot exactly as a new
    /// tracker always did — including one whose GTIN sits at OFFER level
    /// (a passive Safari capture reading `[node, offer]`, as JSON-LD product
    /// pages commonly declare it).
    func testMergingSeedsHistoryFromAMatchingSnapshot() {
        let existing = PriceTracker(
            productName: "Hisense HRFD634BW Fridge", firstStoreURL: "https://jbhifi.example/p/1",
            price: 1999, currency: "AUD", identifiers: ProductIdentifiers(gtin: "9337640009775"))
        let existingItem = store.add(urlString: "https://jbhifi.example/p/1")
        store.savePriceTracker(existing, for: existingItem.id)

        let snapshots = [ProductSnapshot(
            name: "Hisense HRFD634BW Fridge", price: "1899", currency: "AUD",
            url: "https://retravision.example/p/1", host: "retravision.example",
            day: "2026-08-01", capturedAt: "2026-08-01T00:00:00Z", gtin: "9337640009775")]
        let placeholder = store.add(urlString: "https://binglee.example/p/1")
        _ = ProductTrackerMerge.mergeIfPossible(
            product: product(gtin: "9337640009775"), url: URL(string: "https://binglee.example/p/1")!,
            excludingItemID: placeholder.id, store: store,
            comparisonStarter: { _, _, _ in }, snapshotStore: snapshotStore(snapshots))

        let merged = store.item(withID: existingItem.id)?.priceTracker
        let seededStore = merged?.stores.first { $0.urlString.contains("retravision") }
        XCTAssertNotNil(seededStore, "the snapshot's host must be seeded as its own store")
        XCTAssertFalse(seededStore?.priceHistory.isEmpty ?? true)
    }
}

//
//  SaveContentReplacementTests.swift
//  LunaTests
//
//  A recovery file for a save that landed READY with the wrong content runs
//  the ordinary kind handler against a row that already holds something
//  (`claudedocs/llm-handoff.md`). These pin what each handler must do with
//  what is already there: the product tracker keeps its past, and the media
//  save lets go of the file it should never have kept.
//

import LunaHTMLClassification
import LunaMediaDownload
import LunaModels
import LunaPlatforms
import LunaPriceCompare
import LunaStorage
import XCTest
@testable import LunaPriceUI

@MainActor
final class SaveContentReplacementTests: XCTestCase {

    private var directory: URL!
    private var snapshotDirectory: URL?
    private var store: SavesStore!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SaveContentReplacementTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SavesStore(containerURL: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        if let snapshotDirectory { try? FileManager.default.removeItem(at: snapshotDirectory) }
        super.tearDown()
    }

    // MARK: - Product

    /// Re-reading the page of a save that already tracks a product corrects the
    /// tracker instead of starting a new one: the seller's recorded prices and
    /// the alert baseline stand, and the name and current price are the page's.
    func testReplacingAReadyTrackerKeepsItsSellerAndItsHistory() async throws {
        let pageURL = URL(string: "https://shop-a.example/p/1")!
        let ingestor = ProductTrackerIngestor()
        ingestor.comparisonStarter = ForbiddenComparisonStarter(
            reason: "correcting a tracker is not a new save")
        ingestor.snapshotStore = .temporary(directory: &snapshotDirectory)
        ingestor.artworkLoader = StubArtworkLoader(data: nil)
        let refreshed = expectation(description: "the tracker refresh ran")
        let refresher = StubTrackerRefresher()
        refresher.onRefresh = { refreshed.fulfill() }
        ingestor.refresher = refresher

        let item = store.add(urlString: pageURL.absoluteString)
        var tracker = PriceTracker(
            productName: "Acme Accessory Cable", firstStoreURL: pageURL.absoluteString,
            price: Decimal(string: "95")!, currency: "USD",
            now: Date(timeIntervalSince1970: 1_700_000_000))
        tracker.recordPriceSample(
            Decimal(string: "95")!, currency: "USD", urlString: pageURL.absoluteString,
            at: Date(timeIntervalSince1970: 1_700_000_000))
        tracker.setAlertThresholdFraction(0.2)
        store.savePriceTracker(tracker, for: item.id)

        await ingestor.ingest(
            try XCTUnwrap(store.item(withID: item.id)), url: pageURL,
            product: ProductInfo(
                name: "Acme Widget", priceAmount: Decimal(string: "60")!, priceCurrency: "USD",
                imageURL: nil, brand: "Acme", productID: "0012345678905"),
            store: store)
        await fulfillment(of: [refreshed], timeout: 5)

        let saved = try XCTUnwrap(store.item(withID: item.id)?.priceTracker)
        XCTAssertEqual(store.items().count, 1, "no second tracker for the same save")
        XCTAssertEqual(saved.productName, "Acme Widget")
        XCTAssertEqual(saved.brand, "Acme")
        XCTAssertEqual(saved.stores.count, 1)
        XCTAssertEqual(saved.stores.first?.lastPrice, Decimal(string: "60"))
        XCTAssertEqual(
            saved.stores.first?.priceHistory.count, 2,
            "the old observation stands beside the corrected one")
        XCTAssertEqual(
            saved.initialPrice, Decimal(string: "95"), "the alert baseline does not move")
        XCTAssertEqual(saved.alertThresholdFraction, 0.2)
    }

    // MARK: - Media

    /// A media save that already downloaded the wrong file must let go of it:
    /// the library row and the already-downloaded marker are what the download
    /// gate reads, and they would otherwise keep the preview clip forever.
    func testReplacingAReadyMediaSaveDropsTheFileItAlreadyHas() async throws {
        let urlString = "https://www.tiktok.com/@luna/video/7100000000000000000"
        let item = try seedDownloadedMediaSave(urlString: urlString, ready: true)
        defer { clearSharedMedia(urlString: urlString) }

        await PlatformItemIngestor().ingest(
            try XCTUnwrap(SavesStore.shared.item(withID: item.id)), platform: .tiktok,
            platformItemID: "7100000000000000000", store: SavesStore.shared)

        XCTAssertNil(
            SavedMediaStore.shared.existingDownloadedItem(forURLString: urlString),
            "the wrong file's row is gone")
        XCTAssertFalse(
            AutoDownloadSettings.wasDownloaded(urlString),
            "the gate must let a fresh transfer through")
    }

    /// The same handler on a save still being ingested leaves a download alone
    /// — that row is not being corrected, and re-fetching it would be a second
    /// transfer for a file Luna already holds.
    func testAFirstMediaSaveKeepsAnAlreadyDownloadedFile() async throws {
        let urlString = "https://www.tiktok.com/@luna/video/7200000000000000000"
        let item = try seedDownloadedMediaSave(urlString: urlString, ready: false)
        defer { clearSharedMedia(urlString: urlString) }

        await PlatformItemIngestor().ingest(
            try XCTUnwrap(SavesStore.shared.item(withID: item.id)), platform: .tiktok,
            platformItemID: "7200000000000000000", store: SavesStore.shared)

        XCTAssertNotNil(SavedMediaStore.shared.existingDownloadedItem(forURLString: urlString))
        XCTAssertTrue(AutoDownloadSettings.wasDownloaded(urlString))
    }

    /// A media row is keyed by its save, so both stores are seeded together and
    /// both are the SHARED ones — `SavedMediaStore` has no container of its own
    /// to point at a temporary directory.
    private func seedDownloadedMediaSave(urlString: String, ready: Bool) throws -> SavedItem {
        let item = SavedItem(
            seed: urlString, urlString: urlString, title: "A preview", dateAdded: Date(),
            state: ready ? .ready : .pending, platform: .tiktok,
            platformItemID: "seeded")
        SavesStore.shared.seedForTesting(items: [item], contents: [:])
        // A row naming a local file is reconciled away when the file is not
        // there, so the fixture writes one.
        let fileName = "\(item.id.uuidString).mp4"
        try Data("fixture".utf8).write(
            to: SavedMediaStore.shared.mediaDirectory.appendingPathComponent(fileName))
        SavedMediaStore.shared.seedForTesting(items: [SavedMediaItem(
            id: item.id, sourceURLString: urlString, title: "A preview", dateSaved: Date(),
            kind: .video, storageState: .localFile(fileName: fileName),
            thumbnailFileName: nil)])
        AutoDownloadSettings.markDownloaded(urlString)
        return item
    }

    private func clearSharedMedia(urlString: String) {
        SavedMediaStore.shared.wipeForTesting()
        SavesStore.shared.seedForTesting(items: [], contents: [:])
        AutoDownloadSettings.unmarkDownloaded(urlString)
    }
}

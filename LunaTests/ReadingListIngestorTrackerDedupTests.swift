//
//  ReadingListIngestorTrackerDedupTests.swift
//  LunaTests
//

import LunaIngest
import LunaModels
import LunaStorage
import XCTest
@testable import LunaReadingList

/// The re-save dedup: a URL that is already a store inside an existing price
/// tracker merges into it instead of creating a second row. Fix 8 adds a
/// side effect to that path — a merge target that has never been through a
/// fan-out and still holds fewer than two stores kicks a comparison, so a
/// repeat save of (say) an Amazon product actually attempts seller discovery
/// instead of showing nothing forever.
final class ReadingListIngestorTrackerDedupTests: XCTestCase {

    private var tempDirectory: URL!
    private var store: ReadingListStore!
    private var kicked: [(itemID: UUID, url: URL)] = []

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadingListIngestorTrackerDedupTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: tempDirectory)
        kicked = []
        ReadingListIngestor.priceTrackerComparisonKicker = RecordingComparisonKicker { [weak self] itemID, url in
            self?.kicked.append((itemID, url))
        }
    }

    override func tearDown() {
        ReadingListIngestor.priceTrackerComparisonKicker = nil
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    /// A stand-in kicker recording the (item, URL) pairs it was handed.
    private struct RecordingComparisonKicker: PriceTrackerComparisonKicking {
        let record: (UUID, URL) -> Void

        init(_ record: @escaping (UUID, URL) -> Void) {
            self.record = record
        }

        func kickComparison(itemID: UUID, url: URL, store: ReadingListStore) {
            record(itemID, url)
        }
    }

    private func makeIngestor() -> ReadingListIngestor {
        ReadingListIngestor(store: store, surfaceDecision: { _ in .supported })
    }

    private func articleResult(url: URL) -> IngestResult {
        IngestResult(
            url: url,
            outcome: .article(
                ArticleContent(title: "T", blocks: [.init(kind: .paragraph, text: "x", links: [])]),
                html: ""))
    }

    /// A tracker item and a FRESH pending placeholder for a re-save of the
    /// SAME URL — two distinct rows, which is what a real re-save produces
    /// (`ReadingListStore.add(urlString:)` is idempotent on an existing URL,
    /// so it cannot be used twice here to simulate this).
    @discardableResult
    private func seedTrackerAndResave(url: URL, tracker: PriceTracker) -> (trackerItemID: UUID, resaveItem: ReadingListItem) {
        var trackerItem = ReadingListItem(urlString: url.absoluteString)
        trackerItem.priceTracker = tracker
        trackerItem.state = .ready
        let resaveItem = ReadingListItem(urlString: url.absoluteString)
        store.seedForTesting(items: [trackerItem, resaveItem], contents: [:])
        return (trackerItem.id, resaveItem)
    }

    // MARK: - The dedup itself (unaffected by Fix 8)

    func testAReSavedTrackedURLMergesRatherThanCreatingASecondRow() async {
        let trackedURL = URL(string: "https://amazon.example/dp/B0ACME1")!
        let (trackerItemID, resave) = seedTrackerAndResave(
            url: trackedURL,
            tracker: PriceTracker(
                productName: "Toaster", firstStoreURL: trackedURL.absoluteString,
                price: 46, currency: "AUD"))

        let ingestor = makeIngestor()
        _ = await ingestor.applyResult(
            articleResult(url: trackedURL), for: resave, forceArticle: false,
            allowsInteractivePrompt: true)

        XCTAssertNil(store.item(withID: resave.id), "the re-save's own placeholder must not survive")
        XCTAssertNotNil(store.item(withID: trackerItemID)?.priceTracker)
    }

    // MARK: - Fix 8: the comparison kick

    func testAReSaveIntoASellerlessNeverComparedTrackerKicksAComparison() async {
        let trackedURL = URL(string: "https://amazon.example/dp/B0ACME1")!
        let (trackerItemID, resave) = seedTrackerAndResave(
            url: trackedURL,
            tracker: PriceTracker(
                productName: "Toaster", firstStoreURL: trackedURL.absoluteString,
                price: 46, currency: "AUD"))

        let ingestor = makeIngestor()
        _ = await ingestor.applyResult(
            articleResult(url: trackedURL), for: resave, forceArticle: false,
            allowsInteractivePrompt: true)

        XCTAssertEqual(kicked.map(\.itemID), [trackerItemID])
        XCTAssertEqual(kicked.first?.url, trackedURL)
    }

    func testAReSaveIntoATrackerWithTwoOrMoreStoresDoesNotKickAComparison() async {
        let trackedURL = URL(string: "https://amazon.example/dp/B0ACME1")!
        var tracker = PriceTracker(
            productName: "Toaster", firstStoreURL: trackedURL.absoluteString,
            price: 46, currency: "AUD")
        tracker.upsertStore(PriceTrackerStore(urlString: "https://other.example/p/1", lastPrice: 42, currency: "AUD"))
        let (_, resave) = seedTrackerAndResave(url: trackedURL, tracker: tracker)

        let ingestor = makeIngestor()
        _ = await ingestor.applyResult(
            articleResult(url: trackedURL), for: resave, forceArticle: false,
            allowsInteractivePrompt: true)

        XCTAssertTrue(kicked.isEmpty, "a tracker that already has 2+ stores has already been compared")
    }

    func testAReSaveIntoATrackerWithAPendingComparisonDoesNotKickAnother() async {
        let trackedURL = URL(string: "https://amazon.example/dp/B0ACME1")!
        var tracker = PriceTracker(
            productName: "Toaster", firstStoreURL: trackedURL.absoluteString,
            price: 46, currency: "AUD")
        tracker.beginPendingComparison(sourceURLString: trackedURL.absoluteString, at: Date())
        let (_, resave) = seedTrackerAndResave(url: trackedURL, tracker: tracker)

        let ingestor = makeIngestor()
        _ = await ingestor.applyResult(
            articleResult(url: trackedURL), for: resave, forceArticle: false,
            allowsInteractivePrompt: true)

        XCTAssertTrue(kicked.isEmpty, "a run already in flight must not be started twice")
    }

    /// nil (no product kind composed in this process) means nothing runs —
    /// the optional call must not crash and must simply do nothing.
    func testNoInstalledKickerIsANoOp() async {
        ReadingListIngestor.priceTrackerComparisonKicker = nil
        let trackedURL = URL(string: "https://amazon.example/dp/B0ACME1")!
        let (_, resave) = seedTrackerAndResave(
            url: trackedURL,
            tracker: PriceTracker(
                productName: "Toaster", firstStoreURL: trackedURL.absoluteString,
                price: 46, currency: "AUD"))

        let ingestor = makeIngestor()
        let decision = await ingestor.applyResult(
            articleResult(url: trackedURL), for: resave, forceArticle: false,
            allowsInteractivePrompt: true)

        XCTAssertEqual(decision, .supported)
    }
}

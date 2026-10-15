//
//  ArticleCoverThumbnailTests.swift
//  LunaTests
//

import LunaReaderUI
import LunaStorage
import LunaModels
import XCTest

/// Pins the row-thumbnail backfill. The action/share extension saves article
/// content without fetching the page cover, so the app must backfill a row
/// thumbnail for any ready web article missing one. These tests cover the
/// network-free path — reusing an already-downloaded lead image — plus the
/// idempotency and skip guards. `LeadImageExtractor`'s own tests cover the
/// og:image network fetch.
@MainActor
final class ArticleCoverThumbnailTests: XCTestCase {
    private var scratch: URL!
    private var store: SavesStore!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArticleCoverThumbnail-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        store = SavesStore(containerURL: scratch)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    /// A stub image file, well over the 512-byte cover floor. The backfill
    /// only checks file size, not image validity, so raw bytes stand in for a
    /// downloaded lead image.
    private func sampleImageData() -> Data {
        Data(repeating: 0xAB, count: 1024)
    }

    /// Writes `data` under a lead-image file name and returns that name. Real
    /// downloads use fresh generated names; the content links the name directly.
    private func seedDownloadedImage(forImageURL imageURL: String, data: Data) -> String {
        let fileName = "img-\(UUID().uuidString).jpg"
        try? data.write(to: store.articlesDirectory.appendingPathComponent(fileName), options: .atomic)
        return fileName
    }

    /// A ready web article whose lead image is ALREADY downloaded gets that image as
    /// its row thumbnail — no network — and the bytes match the on-disk lead image.
    func testBackfillReusesDownloadedLeadImage() async throws {
        let item = store.add(urlString: "https://example.com/post")
        let imageData = sampleImageData()
        let leadFile = seedDownloadedImage(forImageURL: "https://example.com/lead.jpg", data: imageData)
        let content = ArticleContent(title: "Post", blocks: [
            .init(kind: .paragraph, text: "Intro paragraph.", links: []),
            .init(kind: .image, text: "", links: [],
                  imageURLString: "https://example.com/lead.jpg", imageFileName: leadFile),
        ])
        let ready = store.saveContent(content, for: item)
        XCTAssertEqual(ready.state, .ready)
        XCTAssertNil(ready.thumbnailFileName, "extension save leaves the row without a thumbnail")

        await ArticleCoverThumbnail.backfillThumbnail(for: ready, store: store)

        // The backfill leaves the row without a thumbnail here, which is a
        // separate open failure. Unwrap rather than force: a crash in the test
        // host restarts the runner and discards every suite's totals.
        let refreshed = try XCTUnwrap(store.item(withID: item.id))
        let thumbnailFileName = try XCTUnwrap(
            refreshed.thumbnailFileName, "backfill gives the article a row thumbnail")
        let thumbURL = store.articlesDirectory.appendingPathComponent(thumbnailFileName)
        XCTAssertEqual(try? Data(contentsOf: thumbURL), imageData,
                       "the thumbnail is the already-downloaded lead image (no re-fetch)")
    }

    /// An item that already has a thumbnail is left untouched (idempotent).
    func testBackfillSkipsItemThatAlreadyHasThumbnail() async {
        let item = store.add(urlString: "https://example.com/post")
        let content = ArticleContent(title: "Post", blocks: [
            .init(kind: .image, text: "", links: [],
                  imageURLString: "https://example.com/lead.jpg",
                  imageFileName: seedDownloadedImage(forImageURL: "x", data: sampleImageData())),
        ])
        _ = store.saveContent(content, for: item)
        store.setThumbnail(Data(repeating: 0x01, count: 600), for: item.id)
        let before = store.item(withID: item.id)?.thumbnailFileName

        await ArticleCoverThumbnail.backfillThumbnail(for: store.item(withID: item.id)!, store: store)

        XCTAssertEqual(store.item(withID: item.id)?.thumbnailFileName, before,
                       "an existing thumbnail is never replaced")
    }

    /// Non-article rows (price trackers, documents, platform items) own their own
    /// thumbnail and must be skipped — the backfill never network-fetches for them.
    func testBackfillSkipsNonArticleItems() async {
        let tracker = store.add(urlString: "https://shop.example.com/p")
        store.savePriceTracker(
            PriceTracker(productName: "Widget", firstStoreURL: "https://shop.example.com/p",
                         price: 9, currency: "USD", brand: nil, productID: nil),
            for: tracker.id)
        await ArticleCoverThumbnail.backfillThumbnail(for: store.item(withID: tracker.id)!, store: store)
        XCTAssertNil(store.item(withID: tracker.id)?.thumbnailFileName,
                     "a price tracker is skipped by the article-cover backfill")
    }

    /// A pending (not-yet-ready) article is skipped — the backfill only repairs
    /// finished web articles.
    func testBackfillSkipsPendingItem() async {
        let item = store.add(urlString: "https://example.com/pending")
        await ArticleCoverThumbnail.backfillThumbnail(for: item, store: store)
        XCTAssertNil(store.item(withID: item.id)?.thumbnailFileName)
    }
}

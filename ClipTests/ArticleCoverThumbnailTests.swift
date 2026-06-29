//
//  ArticleCoverThumbnailTests.swift
//  ClipTests
//

import ClipReaderUI
import ClipStorage
import ClipModels
import XCTest

/// Locks in cross-entry-point thumbnail parity: the action/share extension persists
/// article content WITHOUT fetching the page cover (it's short-lived + sandboxed), so
/// the app must backfill a row thumbnail for any ready web article missing one. These
/// tests exercise the network-free backfill path (reuse an already-downloaded lead
/// image) and the idempotency/skip guards — the og:image fetch leg needs the network
/// and is covered by `LeadImageExtractor` extraction tests instead.
@MainActor
final class ArticleCoverThumbnailTests: XCTestCase {
    private var scratch: URL!
    private var store: ReadingListStore!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArticleCoverThumbnail-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: scratch)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    /// A 2x2 PNG, big enough to clear the 512-byte cover floor isn't guaranteed, so
    /// pad with a comment chunk — we only need a real, decodable file on disk.
    private func sampleImageData() -> Data {
        // Minimal valid JPEG-ish blob is awkward; just write >512 bytes of stable bytes.
        // The backfill reads the file by name and only checks the byte floor, so any
        // sufficiently large blob stands in for a downloaded lead image.
        Data(repeating: 0xAB, count: 1024)
    }

    /// Writes `data` to the Articles dir under the stable image-hash name the
    /// downloader uses, and returns that file name.
    private func seedDownloadedImage(forImageURL imageURL: String, data: Data) -> String {
        // Mirror ArticleImageDownloader.stableBase (SHA256 prefix-16) so resolveLocalImages finds it.
        // We can't reach the private helper, so persist content with the file linked directly instead.
        let fileName = "lead-\(UUID().uuidString).jpg"
        try? data.write(to: store.articlesDirectory.appendingPathComponent(fileName), options: .atomic)
        return fileName
    }

    /// A ready web article whose lead image is ALREADY downloaded gets that image as
    /// its row thumbnail — no network — and the bytes match the on-disk lead image.
    func testBackfillReusesDownloadedLeadImage() async {
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

        let refreshed = store.item(withID: item.id)
        XCTAssertNotNil(refreshed?.thumbnailFileName, "backfill gives the article a row thumbnail")
        let thumbURL = store.articlesDirectory.appendingPathComponent(refreshed!.thumbnailFileName!)
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

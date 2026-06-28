//
//  PreloadStoreTests.swift
//  ClipTests
//

import ClipReadingList
import ClipDesignSystem
import ClipStorage
import ClipModels
import XCTest
@testable import Clip

final class PreloadStoreTests: XCTestCase {
    private var dir: URL!
    private var store: PreloadStore!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreloadTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = PreloadStore(containerURL: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func url(_ s: String) -> URL { URL(string: s)! }
    private func article(_ title: String) -> ArticleContent {
        ArticleContent(title: title, blocks: [
            .init(kind: .paragraph, text: String(repeating: "a", count: 1500), links: []),
        ])
    }

    func testKeyCanonicalizationIgnoresFragmentAndHostCase() {
        let a = PreloadStore.key(for: url("https://Example.com/story#section"))
        let b = PreloadStore.key(for: url("https://example.com/story"))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, PreloadStore.key(for: url("https://example.com/other")))
    }

    func testRecordAndReadBackArticle() {
        let u = url("https://example.com/a")
        store.record(url: u, rootID: UUID(), kind: .article, depthRemaining: 1, content: article("A"))
        XCTAssertEqual(store.articleContent(for: u)?.title, "A")
        XCTAssertEqual(store.entry(for: u)?.kind, .article)
    }

    // MARK: - Synchronous / in-memory cache (instant, spinner-free opens)

    /// `record` warms the in-memory cache so the very first tap is a synchronous hit.
    func testRecordWarmsSynchronousCache() {
        let u = url("https://example.com/sync")
        store.record(url: u, rootID: UUID(), kind: .article, depthRemaining: 0, content: article("Sync"))
        XCTAssertEqual(store.synchronousArticleContent(for: u)?.title, "Sync")
    }

    /// A fresh store (cold memory, warm disk — i.e. after relaunch) still resolves a
    /// preloaded article synchronously by decoding from disk and warming memory.
    func testSynchronousReadFromDiskOnColdMemory() {
        let u = url("https://example.com/cold")
        store.record(url: u, rootID: UUID(), kind: .article, depthRemaining: 0, content: article("Cold"))
        // A new store instance over the same container has an empty in-memory cache.
        let fresh = PreloadStore(containerURL: dir)
        XCTAssertEqual(fresh.synchronousArticleContent(for: u)?.title, "Cold")
        // Second call is now served from the warmed memory cache (same result).
        XCTAssertEqual(fresh.synchronousArticleContent(for: u)?.title, "Cold")
    }

    func testSynchronousReadMissReturnsNil() {
        XCTAssertNil(store.synchronousArticleContent(for: url("https://example.com/never")))
    }

    /// Releasing the last owner evicts the entry from the in-memory cache too (not just
    /// disk), so a stale page can't be served synchronously after teardown.
    func testReleaseEvictsSynchronousCache() {
        let u = url("https://example.com/evict")
        let root = UUID()
        store.record(url: u, rootID: root, kind: .article, depthRemaining: 0, content: article("E"))
        XCTAssertNotNil(store.synchronousArticleContent(for: u))
        store.releaseTree(rootID: root)
        XCTAssertNil(store.synchronousArticleContent(for: u))
    }

    func testRefcountKeepsSharedCopyUntilLastOwnerReleased() {
        let u = url("https://example.com/shared")
        let root1 = UUID(), root2 = UUID()
        store.record(url: u, rootID: root1, kind: .article, depthRemaining: 1, content: article("S"))
        store.record(url: u, rootID: root2, kind: .article, depthRemaining: 1, content: article("S"))
        XCTAssertEqual(store.entry(for: u)?.owners.count, 2)
        let file = store.contentURL(fileName: store.entry(for: u)!.contentFile!)

        // Releasing one owner leaves the shared copy intact.
        store.releaseTree(rootID: root1)
        XCTAssertEqual(store.entry(for: u)?.owners.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        // Releasing the last owner deletes the entry and its file.
        store.releaseTree(rootID: root2)
        XCTAssertNil(store.entry(for: u))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAddOwnerForDedup() {
        let u = url("https://example.com/x")
        let root1 = UUID(), root2 = UUID()
        store.record(url: u, rootID: root1, kind: .article, depthRemaining: 1, content: article("X"))
        let entry = store.addOwner(root2, toKey: PreloadStore.key(for: u))
        XCTAssertEqual(entry?.owners, [root1.uuidString, root2.uuidString])
    }

    func testUnrepresentableStoresNoFile() {
        let u = url("https://paywall.example/x")
        let e = store.record(url: u, rootID: UUID(), kind: .unrepresentable, depthRemaining: 1)
        XCTAssertEqual(e.state, .failed)
        XCTAssertNil(e.contentFile)
        XCTAssertNil(store.articleContent(for: u))
    }

    func testOutboundURLsDedupesAndFiltersToHTTP() {
        let content = ArticleContent(title: "T", blocks: [
            .init(kind: .paragraph, text: "x", links: [
                .init(start: 0, length: 1, urlString: "https://a.com/1"),
                .init(start: 0, length: 1, urlString: "https://a.com/1"), // dup
                .init(start: 0, length: 1, urlString: "mailto:x@y.com"),  // non-http
            ]),
            .init(kind: .paragraph, text: "y", links: [
                .init(start: 0, length: 1, urlString: "http://b.com/2"),
            ]),
        ])
        XCTAssertEqual(
            PreloadCoordinator.outboundURLs(from: content).map(\.absoluteString),
            ["https://a.com/1", "http://b.com/2"])
    }

    func testPreloadDepthClamps() {
        let original = ReaderSettings.preloadDepth
        defer { ReaderSettings.preloadDepth = original }
        ReaderSettings.preloadDepth = 9
        XCTAssertEqual(ReaderSettings.preloadDepth, 5)
        ReaderSettings.preloadDepth = -2
        XCTAssertEqual(ReaderSettings.preloadDepth, 0)
    }

    // MARK: - Ephemeral (session) ownership — the +1-depth speculative preloads

    func testSessionOnlyOwnedEntryDeletedOnRelease() {
        let u = url("https://example.com/speculative")
        let session = UUID()
        store.record(url: u, rootID: session, kind: .article, depthRemaining: 0, content: article("S"))
        XCTAssertNotNil(store.articleContent(for: u))
        // Exiting the reader releases the session → the purely-speculative page is gone.
        store.releaseTree(rootID: session)
        XCTAssertNil(store.entry(for: u))
    }

    func testWithinDepthEntrySurvivesSessionRelease() {
        let u = url("https://example.com/durable")
        let root = UUID(), session = UUID()
        // A within-depth page is owned by BOTH the durable root and the session.
        store.record(url: u, rootID: root, kind: .article, depthRemaining: 1, content: article("D"))
        store.record(url: u, rootID: session, kind: .article, depthRemaining: 1, content: article("D"))
        store.releaseTree(rootID: session)
        // Session gone, durable root remains → page survives.
        XCTAssertEqual(store.entry(for: u)?.owners, [root.uuidString])
        XCTAssertNotNil(store.articleContent(for: u))
    }

    // MARK: - Image reference counting via the preload lifecycle

    /// `PreloadStore(containerURL:)` builds its `ImageReferenceStore` on the SAME
    /// container, so a preloaded page's images live in `<dir>/Articles`.
    private var articlesDir: URL { dir.appendingPathComponent("Articles", isDirectory: true) }

    private func makeImageFile(_ name: String) {
        try? FileManager.default.createDirectory(at: articlesDir, withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: articlesDir.appendingPathComponent(name))
    }

    private func imageExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: articlesDir.appendingPathComponent(name).path)
    }

    private func articleWithImage(_ file: String) -> ArticleContent {
        ArticleContent(title: "A", blocks: [
            .init(kind: .image, text: "", links: [], imageFileName: file),
            .init(kind: .paragraph, text: String(repeating: "a", count: 1500), links: []),
        ])
    }

    func testReleasingLastOwnerDeletesPreloadImages() {
        makeImageFile("img-pre.jpg")
        let u = url("https://example.com/withimage")
        let root = UUID()
        store.record(url: u, rootID: root, kind: .article, depthRemaining: 0,
                     content: articleWithImage("img-pre.jpg"))
        XCTAssertTrue(imageExists("img-pre.jpg"))
        store.releaseTree(rootID: root)
        XCTAssertFalse(imageExists("img-pre.jpg"))
    }

    func testSharedPreloadImageKeptWhileAnotherPageOwnsIt() {
        makeImageFile("img-shared.jpg")
        let a = url("https://example.com/a"), b = url("https://example.com/b")
        let r1 = UUID(), r2 = UUID()
        // Two distinct preloaded pages reference the same downloaded image.
        store.record(url: a, rootID: r1, kind: .article, depthRemaining: 0,
                     content: articleWithImage("img-shared.jpg"))
        store.record(url: b, rootID: r2, kind: .article, depthRemaining: 0,
                     content: articleWithImage("img-shared.jpg"))
        store.releaseTree(rootID: r1)
        XCTAssertTrue(imageExists("img-shared.jpg"))   // page B still owns it
        store.releaseTree(rootID: r2)
        XCTAssertFalse(imageExists("img-shared.jpg"))  // last page gone → image deleted
    }
}

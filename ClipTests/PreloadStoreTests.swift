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
}

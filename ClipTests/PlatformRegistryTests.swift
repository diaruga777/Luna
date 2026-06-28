//
//  PlatformRegistryTests.swift
//  ClipTests
//

import ClipStorage
import ClipURLClassification
import ClipModels
import XCTest
@testable import Clip

/// A stand-in platform module for testing registry dispatch.
private struct FakePlatform: PlatformModule {
    let platform: ContentPlatform
    let glyphSymbolName = "circle"
    let host: String
    func classify(_ urlString: String) -> PlatformMatch? {
        urlString.contains(host) ? PlatformMatch(platform: platform, itemID: "id-1") : nil
    }
    func subtitle(for item: ReadingListItem) -> String? { nil }
    func appDeepLink(for item: ReadingListItem) -> URL? { nil }
    func embed(for item: ReadingListItem) -> PlatformEmbed? { nil }
}

final class PlatformRegistryTests: XCTestCase {

    func testDetectReturnsFirstMatchingModule() {
        let registry = PlatformRegistry(modules: [
            FakePlatform(platform: .bluesky, host: "bsky.app"),
            FakePlatform(platform: .reddit, host: "reddit.com"),
        ])
        XCTAssertEqual(registry.detect("https://bsky.app/profile/a/post/b")?.platform, .bluesky)
        XCTAssertEqual(registry.detect("https://reddit.com/r/x/comments/y")?.platform, .reddit)
        XCTAssertNil(registry.detect("https://example.com/article"))
    }

    func testRegistryClassifiesYouTubeAndRejects() {
        // Recognition is the registry's `detect` (backed by `PlatformRecognizer`) —
        // the per-module `classify` was removed (modules keep rendering only).
        let match = PlatformRegistry.shared.detect("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertEqual(match?.platform, .youtube)
        XCTAssertEqual(match?.itemID, "dQw4w9WgXcQ")
        XCTAssertNil(PlatformRegistry.shared.detect("https://example.com/not-a-video"))
    }

    func testDefaultRegistryRecognizesYouTube() {
        XCTAssertEqual(
            PlatformRegistry.shared.detect("https://youtu.be/dQw4w9WgXcQ")?.platform, .youtube)
    }
}

final class PlatformMetadataStoreTests: XCTestCase {

    private var scratch: URL!
    private var store: ReadingListStore!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlatformStore-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: scratch)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    func testSavePlatformMetadataMarksReadyWithFields() {
        let item = store.add(urlString: "https://bsky.app/profile/a/post/b")
        let saved = store.savePlatformMetadata(
            platform: .bluesky, platformItemID: "b", title: "A skeet", creator: "@alice",
            thumbnailFileName: nil, mediaCreatorName: nil, mediaItemTitle: nil,
            mediaSourceService: nil, for: item.id)
        XCTAssertEqual(saved?.state, .ready)
        XCTAssertEqual(saved?.platform, .bluesky)
        XCTAssertEqual(saved?.platformItemID, "b")
        XCTAssertEqual(saved?.channelName, "@alice")
        XCTAssertTrue(saved?.isPlatformItem ?? false)
    }

    func testPlatformFieldsRoundTripThroughJSON() {
        let item = store.add(urlString: "https://open.spotify.com/track/abc")
        _ = store.savePlatformMetadata(
            platform: .music, platformItemID: "abc", title: "Song", creator: "Artist",
            thumbnailFileName: nil, mediaCreatorName: "Artist", mediaItemTitle: "Song",
            mediaSourceService: .spotify, for: item.id)
        // Re-read from disk (fresh decode).
        let reloaded = store.item(withID: item.id)
        XCTAssertEqual(reloaded?.platform, .music)
        XCTAssertEqual(reloaded?.mediaSourceService, .spotify)
        XCTAssertEqual(reloaded?.mediaCreatorName, "Artist")
        XCTAssertTrue(reloaded?.isURLlessMedia ?? false)
    }
}

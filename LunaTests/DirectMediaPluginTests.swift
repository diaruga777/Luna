//
//  DirectMediaPluginTests.swift
//  LunaTests
//

import LunaModels
import LunaURLClassification
import XCTest

/// `direct-media.js` against `DirectMediaURL`, the table the Swift resolver's
/// first step reads.
///
/// The plugin cannot import that table, so this is the pin that keeps the copy
/// honest: every extension one recognizes, the other recognizes as the same
/// kind.
final class DirectMediaPluginTests: XCTestCase {

    private var harness: MediaPluginHarness!

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try MediaPluginHarness("direct-media", id: "app.luna.direct-media")
    }

    override func tearDown() {
        harness.cleanUp()
        harness = nil
        super.tearDown()
    }

    /// One case per extension the Swift table names, plus the shapes a CDN adds
    /// around one.
    func testEveryDirectMediaURLResolvesToTheKindTheSwiftTableNames() async {
        let urls = [
            "https://cdn.example.com/photo.jpg",
            "https://cdn.example.com/photo.jpeg",
            "https://cdn.example.com/photo.png",
            "https://cdn.example.com/photo.webp",
            "https://cdn.example.com/photo.avif",
            "https://cdn.example.com/photo.heic",
            "https://cdn.example.com/photo.heif",
            "https://cdn.example.com/loop.gif",
            "https://cdn.example.com/clip.mp4",
            "https://cdn.example.com/clip.mov",
            "https://cdn.example.com/clip.m4v",
            "https://cdn.example.com/song.mp3",
            "https://cdn.example.com/song.m4a",
            "https://cdn.example.com/song.aac",
            "https://cdn.example.com/song.flac",
            "https://cdn.example.com/song.wav",
            "https://cdn.example.com/song.aif",
            "https://cdn.example.com/song.aiff",
            "https://cdn.example.com/song.caf",
            // A signed link keeps its extension: the query is not part of it.
            "https://cdn.example.com/dir.with.dots/clip.mp4?token=abc&x=1#top",
            "https://CDN.EXAMPLE.com/UPPER.MP4",
        ]
        for urlString in urls {
            let url = URL(string: urlString)!
            let expected = MediaAsset.direct(url: url)
            let assets = await harness.resolve(urlString)

            XCTAssertEqual(assets.shapes, expected.map { [$0] }?.shapes ?? [], urlString)
        }
    }

    /// A page, a document and a non-http scheme are not assets, so the plugin
    /// declines and the Swift classifier decides.
    func testNonMediaURLsAreDeclined() async {
        for urlString in [
            "https://example.com/article",
            "https://example.com/paper.pdf",
            "https://example.com/archive.zip",
            "https://example.com/photo",
            "ftp://example.com/clip.mp4",
        ] {
            XCTAssertNil(URL(string: urlString).flatMap(MediaAsset.direct(url:)), urlString)
            let verdict = await harness.classify(urlString)
            XCTAssertEqual(verdict, .declined, urlString)
        }
    }

    /// The plugin runs after every host-matched plugin, so a platform's own
    /// post page keeps its resolver even when the path ends in a media
    /// extension.
    func testThePluginMatchesEveryHostAndSoRunsLast() {
        let summary = harness.runner.runtime.loadedPlugins.first
        XCTAssertEqual(summary?.matchesAnyHost, true)
        XCTAssertTrue(summary?.matches(host: "cdn.example.com") ?? false)
    }
}

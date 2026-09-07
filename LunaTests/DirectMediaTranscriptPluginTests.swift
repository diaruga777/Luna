//
//  DirectMediaTranscriptPluginTests.swift
//  LunaTests
//

import LunaModels
import XCTest

/// `direct-media-transcript.js`: a URL that is itself an audio or video file
/// is its own transcription source; images and GIFs are declined.
final class DirectMediaTranscriptPluginTests: XCTestCase {

    private var harness: TranscriptPluginHarness!

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try TranscriptPluginHarness(
            "direct-media-transcript", id: "app.luna.direct-media.transcript")
    }

    override func tearDown() {
        harness.cleanUp()
        harness = nil
        super.tearDown()
    }

    func testAudioAndVideoFilesAreTheirOwnSource() async throws {
        let cases: [(String, String, String)] = [
            ("https://cdn.example.com/talks/keynote.mp3?token=1", "audio", "keynote.mp3"),
            ("https://cdn.example.com/song.m4a", "audio", "song.m4a"),
            ("https://cdn.example.com/clip.mov", "video", "clip.mov"),
            ("https://CDN.EXAMPLE.com/UPPER.MP4", "video", "UPPER.MP4"),
        ]
        for (url, type, title) in cases {
            let article = try await harness.requireArticle(url)
            XCTAssertEqual(article.transcription?.type.rawValue, type, url)
            XCTAssertEqual(article.transcription?.url.absoluteString, url, url)
            XCTAssertEqual(article.title, title, url)
            XCTAssertTrue(article.html.isEmpty, url)
        }
    }

    func testImagesGIFsAndPagesAreDeclined() async {
        for url in [
            "https://cdn.example.com/photo.jpg",
            "https://cdn.example.com/loop.gif",
            "https://example.com/watch/clip",
        ] {
            let verdict = await harness.classify(url)
            XCTAssertEqual(verdict, .declined, url)
        }
    }

    /// The media twin steps aside for a transcribe intent and still claims a
    /// plain save.
    func testTheMediaTwinDeclinesTheTranscribeIntent() async throws {
        try await assertMediaTwinDeclinesTranscribeIntent(
            "direct-media", id: "app.luna.direct-media", url: "https://cdn.example.com/clip.mp4")
    }
}

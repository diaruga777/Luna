//
//  TikTokTranscriptPluginTests.swift
//  LunaTests
//

import LunaModels
import LunaPluginIngest
import XCTest

/// `tiktok-transcript.js`: TikTok's own WebVTT captions when the item carries
/// them, else the video file with the CDN's Referer.
final class TikTokTranscriptPluginTests: XCTestCase {

    private var harness: TranscriptPluginHarness!

    private static let captionedURL = "https://www.tiktok.com/@fixture/video/7300000000000000000"
    private static let plainURL = "https://www.tiktok.com/@someone/video/7123456789012345678"
    private static let asrCaptionsURL = "https://captions.example.com/tiktok.vtt"
    private static let translatedCaptionsURL = "https://captions.example.com/tiktok-mt.vtt"

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try TranscriptPluginHarness("tiktok-transcript", id: "app.luna.tiktok.transcript")
    }

    override func tearDown() {
        harness.cleanUp()
        harness = nil
        super.tearDown()
    }

    private func fixture(_ name: String) throws -> String {
        try MediaPluginHarness.fixture("tiktok/\(name)")
    }

    /// The ASR track is preferred over the machine translation, its cues
    /// become paragraphs (tags stripped, a rolling repeat dropped, a pause
    /// starting a new paragraph), and no file is offered.
    func testCaptionsBecomeTheArticle() async throws {
        harness.fetcher.respond(
            to: Self.captionedURL, body: try fixture("rehydration-subtitles.html"))
        harness.fetcher.respond(to: Self.asrCaptionsURL, body: try fixture("subtitles.vtt"))

        let article = try await harness.requireArticle(Self.captionedURL)

        XCTAssertNil(article.transcription)
        XCTAssertEqual(
            article.html,
            "<p>Hello and welcome. This clip is about testing captions.</p>\n"
                + "<p>A pause starts a new paragraph.</p>")
        XCTAssertEqual(article.title, "A synthetic clip about testing")
        XCTAssertEqual(article.author, "Fixture Creator")
        XCTAssertEqual(article.language, "en-US")
        XCTAssertFalse(
            harness.fetcher.requests.contains { $0.url.absoluteString == Self.translatedCaptionsURL })
    }

    /// An item without captions offers its play address as the file, carrying
    /// the Referer the CDN requires.
    func testTheVideoIsTheFallback() async throws {
        harness.fetcher.respond(to: Self.plainURL, body: try fixture("rehydration-video.html"))

        let article = try await harness.requireArticle(Self.plainURL)
        let spec = try XCTUnwrap(article.transcription)

        XCTAssertEqual(spec.type.rawValue, "video")
        XCTAssertEqual(spec.url.absoluteString, "https://video.example.com/tiktok.mp4")
        XCTAssertEqual(spec.headers["Referer"], "https://www.tiktok.com/")
        XCTAssertEqual(article.title, "TikTok 7123456789012345678")
    }

    /// A caption file that cannot be read falls through to the video.
    func testAnUnreadableCaptionFileFallsThroughToTheVideo() async throws {
        harness.fetcher.respond(
            to: Self.captionedURL, body: try fixture("rehydration-subtitles.html"))
        harness.fetcher.respond(to: Self.asrCaptionsURL, status: 403, body: "")

        let article = try await harness.requireArticle(Self.captionedURL)

        XCTAssertEqual(article.transcription?.type.rawValue, "video")
        XCTAssertEqual(article.html, "<p>A synthetic clip about testing</p>")
    }

    /// A photo carousel has no speech.
    func testAPhotoCarouselIsDeclined() async throws {
        harness.fetcher.respond(
            to: Self.plainURL, body: try fixture("api-data-photo-carousel.html"))

        let article = await harness.article(Self.plainURL)

        XCTAssertNil(article)
    }

    /// The media twin steps aside for a transcribe intent and still claims a
    /// plain save.
    func testTheMediaTwinDeclinesTheTranscribeIntent() async throws {
        try await assertMediaTwinDeclinesTranscribeIntent(
            "tiktok", id: "app.luna.tiktok", url: Self.plainURL)
    }
}

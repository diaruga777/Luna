//
//  FacebookTranscriptPluginTests.swift
//  LunaTests
//

import LunaModels
import LunaPluginKit
import XCTest

/// `facebook-transcript.js`: the page's playable MP4, HD before SD, is the
/// source; a page with only a poster is declined.
final class FacebookTranscriptPluginTests: XCTestCase {

    private var harness: TranscriptPluginHarness!

    private static let reelURL = "https://www.facebook.com/reel/1661338298308685/"
    private static let embedURL = "https://www.facebook.com/plugins/video.php?href="
        + "https%3A%2F%2Fwww.facebook.com%2Freel%2F1661338298308685%2F"

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try TranscriptPluginHarness(
            "facebook-transcript", id: "app.luna.facebook.transcript")
    }

    override func tearDown() {
        harness.cleanUp()
        harness = nil
        super.tearDown()
    }

    private func fixture(_ name: String) throws -> String {
        try MediaPluginHarness.fixture("facebook/\(name)")
    }

    func testTheEmbedPageNamesTheHDVideo() async throws {
        harness.fetcher.respond(to: Self.embedURL, body: try fixture("plugin-embed-hd.html"))

        let article = try await harness.requireArticle(Self.reelURL)
        let spec = try XCTUnwrap(article.transcription)

        XCTAssertEqual(spec.type.rawValue, "video")
        XCTAssertEqual(spec.url.absoluteString, "https://video.example.com/reel-hd.mp4")
        XCTAssertEqual(article.title, "Facebook 1661338298308685")
    }

    /// A poster-only page names no video, and the ladder ends declined when
    /// every stage answers the same.
    func testAPosterOnlyPageIsDeclined() async throws {
        harness.fetcher.fallback = .success(PluginFetchResponse(
            status: 200, finalURL: Self.reelURL, headers: [:],
            body: Data(try fixture("poster-only.html").utf8), truncated: false, redirected: false))

        let declined = await harness.article(Self.reelURL)

        XCTAssertNil(declined)
    }

    /// The media twin steps aside for a transcribe intent and still claims a
    /// plain save.
    func testTheMediaTwinDeclinesTheTranscribeIntent() async throws {
        try await assertMediaTwinDeclinesTranscribeIntent(
            "facebook", id: "app.luna.facebook", url: Self.reelURL)
    }
}

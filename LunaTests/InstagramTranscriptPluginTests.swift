//
//  InstagramTranscriptPluginTests.swift
//  LunaTests
//

import LunaModels
import XCTest

/// `instagram-transcript.js`: the reel's MP4 from whichever keyless source
/// names it is the source; a still-only post is declined.
final class InstagramTranscriptPluginTests: XCTestCase {

    private var harness: TranscriptPluginHarness!

    private static let reelURL = "https://www.instagram.com/reel/DbripgRKlb_/"
    private static let crawlerURL = "https://www.instagram.com/p/DbripgRKlb_/"
    private static let graphQLURL =
        "https://www.instagram.com/graphql/query/?doc_id=10015901848480474&variables="
        + "%7B%22shortcode%22%3A%22DbripgRKlb_%22%7D"

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try TranscriptPluginHarness(
            "instagram-transcript", id: "app.luna.instagram.transcript")
    }

    override func tearDown() {
        harness.cleanUp()
        harness = nil
        super.tearDown()
    }

    private func fixture(_ name: String) throws -> String {
        try MediaPluginHarness.fixture("instagram/\(name)")
    }

    func testTheCrawlerPageNamesTheVideo() async throws {
        harness.fetcher.respond(to: Self.crawlerURL, body: try fixture("crawler-reel.html"))

        let article = try await harness.requireArticle(Self.reelURL)
        let spec = try XCTUnwrap(article.transcription)

        XCTAssertEqual(spec.type.rawValue, "video")
        XCTAssertEqual(spec.url.absoluteString, "https://video.example.com/reel.mp4")
        XCTAssertEqual(article.title, "Instagram DbripgRKlb_")
        XCTAssertEqual(harness.fetcher.requests.count, 1, "the first source answered")
    }

    func testTheQueryNamesTheVideoWhenThePageIsGated() async throws {
        harness.fetcher.respond(to: Self.crawlerURL, body: try fixture("crawler-gated.html"))
        harness.fetcher.respond(to: Self.graphQLURL, body: try fixture("graphql-reel.json"))

        let article = try await harness.requireArticle(Self.reelURL)

        XCTAssertEqual(
            article.transcription?.url.absoluteString, "https://video.example.com/reel.mp4")
    }

    /// A photo has no speech, and a video no source could name is never
    /// replaced by its poster.
    func testStillsAreDeclined() async throws {
        harness.fetcher.respond(to: Self.crawlerURL, status: 401, body: "")
        harness.fetcher.respond(to: Self.graphQLURL, body: try fixture("graphql-photo.json"))
        let declined = await harness.article(Self.reelURL)
        XCTAssertNil(declined)

        harness.fetcher.responses = [:]
        harness.fetcher.respond(to: Self.crawlerURL, body: try fixture("walled.html"))
        harness.fetcher.respond(to: Self.graphQLURL, body: try fixture("graphql-video-no-url.json"))
        let declinedAgain = await harness.article(Self.reelURL)
        XCTAssertNil(declinedAgain)
    }

    /// The media twin steps aside for a transcribe intent and still claims a
    /// plain save.
    func testTheMediaTwinDeclinesTheTranscribeIntent() async throws {
        try await assertMediaTwinDeclinesTranscribeIntent(
            "instagram", id: "app.luna.instagram", url: Self.reelURL)
    }
}

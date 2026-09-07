//
//  RedditTranscriptPluginTests.swift
//  LunaTests
//

import LunaModels
import XCTest

/// `reddit-transcript.js`: the separate audio leg of a video with sound is the
/// whole source; a silent video is declined.
final class RedditTranscriptPluginTests: XCTestCase {

    private var harness: TranscriptPluginHarness!

    private static let postURL = "https://www.reddit.com/r/videos/comments/abc123/title/"
    private static let listingURL = "https://www.reddit.com/comments/abc123.json"

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try TranscriptPluginHarness("reddit-transcript", id: "app.luna.reddit.transcript")
    }

    override func tearDown() {
        harness.cleanUp()
        harness = nil
        super.tearDown()
    }

    private func fixture(_ name: String) throws -> String {
        try MediaPluginHarness.fixture("reddit/\(name)")
    }

    /// The audio companion — the sibling `audio` path the media twin rides as
    /// `audioURL` — is offered alone, as an audio file.
    func testTheAudioLegIsTheSource() async throws {
        harness.fetcher.respond(to: Self.listingURL, body: try fixture("video-with-audio.json"))

        let article = try await harness.requireArticle(Self.postURL)
        let spec = try XCTUnwrap(article.transcription)

        XCTAssertEqual(spec.type.rawValue, "audio")
        XCTAssertEqual(spec.url.absoluteString, "https://v.redd.it/abc123def456/audio")
        XCTAssertEqual(spec.headers["Referer"], "https://www.reddit.com/")
        XCTAssertEqual(article.title, "Reddit abc123")
        XCTAssertTrue(article.html.isEmpty)
    }

    /// A video without sound has nothing to transcribe.
    func testASilentVideoIsDeclined() async throws {
        harness.fetcher.respond(to: Self.listingURL, body: try fixture("silent-video.json"))

        let declined = await harness.article(Self.postURL)

        XCTAssertNil(declined)
    }

    /// A post with no hosted video is declined.
    func testAnImagePostIsDeclined() async throws {
        harness.fetcher.respond(to: Self.listingURL, body: try fixture("image-post.json"))

        let declined = await harness.article(Self.postURL)

        XCTAssertNil(declined)
    }

    /// The media twin steps aside for a transcribe intent and still claims a
    /// plain save.
    func testTheMediaTwinDeclinesTheTranscribeIntent() async throws {
        try await assertMediaTwinDeclinesTranscribeIntent(
            "reddit", id: "app.luna.reddit", url: Self.postURL)
    }
}

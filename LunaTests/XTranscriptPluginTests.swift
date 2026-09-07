//
//  XTranscriptPluginTests.swift
//  LunaTests
//

import LunaModels
import XCTest

/// `x-transcript.js`: a video post's MP4 is the source and the post's own
/// words lead the article; a post with no video is declined.
final class XTranscriptPluginTests: XCTestCase {

    private var harness: TranscriptPluginHarness!

    private static let videoPostURL = "https://x.com/emollick/status/2082319924987351510"
    private static let threadURL = "https://api.fxtwitter.com/2/thread/2082319924987351510"
    private static let statusURL = "https://api.fxtwitter.com/status/2082319924987351510"

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try TranscriptPluginHarness("x-transcript", id: "app.luna.x.transcript")
    }

    override func tearDown() {
        harness.cleanUp()
        harness = nil
        super.tearDown()
    }

    private func fixture(_ name: String) throws -> String {
        try MediaPluginHarness.fixture("x/\(name)")
    }

    func testTheVideoIsTheSourceAndThePostTextLeads() async throws {
        harness.fetcher.respond(to: Self.threadURL, body: try fixture("x-video-post.json"))

        let article = try await harness.requireArticle(Self.videoPostURL)
        let spec = try XCTUnwrap(article.transcription)

        XCTAssertEqual(spec.type.rawValue, "video")
        XCTAssertTrue(spec.url.absoluteString.hasPrefix("https://video.twimg.com/amplify_video/"))
        XCTAssertEqual(article.author, "Ethan Mollick")
        XCTAssertTrue(article.title.hasPrefix("Those who follow my feed"))
        XCTAssertTrue(article.html.hasPrefix("<p>Those who follow my feed"))
    }

    /// A photo post and a text post have nothing to transcribe.
    func testPostsWithoutAVideoAreDeclined() async throws {
        for name in ["x-photo-post.json", "x-standalone-short.json", "x-long-form-article.json"] {
            harness.fetcher.responses = [:]
            harness.fetcher.respond(to: Self.threadURL, body: try fixture(name))
            let declined = await harness.article(Self.videoPostURL)
            XCTAssertNil(declined, name)
        }
    }

    /// The single-post route answers when the thread route fails.
    func testFallsBackToTheSinglePostRoute() async throws {
        harness.fetcher.respond(to: Self.threadURL, status: 500, body: "")
        harness.fetcher.respond(to: Self.statusURL, body: try fixture("x-video-post.json"))

        let article = await harness.article(Self.videoPostURL)
        XCTAssertNotNil(article?.transcription)
    }

    /// The media twin steps aside for a transcribe intent and still claims a
    /// plain save.
    func testTheMediaTwinDeclinesTheTranscribeIntent() async throws {
        try await assertMediaTwinDeclinesTranscribeIntent("x", id: "app.luna.x", url: Self.videoPostURL)
    }
}

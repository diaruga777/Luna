//
//  XPluginTests.swift
//  LunaTests
//

import LunaModels
import XCTest

/// `x.js` against the recorded fxtwitter payloads.
///
/// The plugin runs BEFORE the Swift classifier, so its decline is what keeps a
/// long-form post with the reader (`XPostIngestProcessor`, LunaArticleIngest).
/// The two suites read the same payloads: `XPostExtractorTests` asserts which
/// ones become articles, and this asserts the plugin hands exactly those back.
final class XPluginTests: XCTestCase {

    private var harness: MediaPluginHarness!

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try MediaPluginHarness("x", id: "app.luna.x")
    }

    override func tearDown() {
        harness.cleanUp()
        harness = nil
        super.tearDown()
    }

    private func postURL(_ id: String) -> String {
        "https://x.com/someone/status/\(id)"
    }

    /// Serves the v2 thread route for `id` and leaves the v1 route unanswered,
    /// the way the mirror behaves when it has the thread.
    private func serve(_ fixture: String, id: String) throws {
        harness.fetcher.respond(
            to: "https://api.fxtwitter.com/2/thread/\(id)",
            body: try MediaPluginHarness.fixture("x/\(fixture)"))
    }

    /// A post the user shared for its video resolves to that video.
    func testVideoPostResolvesItsMP4() async throws {
        let id = "2082319924987351510"
        try serve("x-video-post.json", id: id)

        let assets = await harness.resolve(postURL(id))

        XCTAssertEqual(assets.count, 1)
        XCTAssertEqual(assets.first?.kind, .video)
        XCTAssertEqual(
            assets.first?.url.absoluteString,
            "https://video.twimg.com/amplify_video/2082317468211585024/vid/avc1/1280x704/"
                + "yHZp_y-JcL_ej8j6.mp4?tag=29")
    }

    /// X serves a "GIF" as an MP4, so it resolves as video with its poster.
    func testGIFPostResolvesAsVideoWithItsPoster() async throws {
        let id = "2082319924987351577"
        try serve("x-gif-post.json", id: id)

        let assets = await harness.resolve(postURL(id))

        XCTAssertEqual(assets.shapes.map(\.kind), [.video])
        XCTAssertEqual(
            assets.first?.thumbnailURL?.absoluteString,
            "https://pbs.twimg.com/tweet_video_thumb/loop.jpg")
    }

    /// Photos resolve in display order.
    func testPhotoPostResolvesEveryImageInOrder() async throws {
        let id = "2082319924987351599"
        try serve("x-photo-post.json", id: id)

        let assets = await harness.resolve(postURL(id))

        XCTAssertEqual(assets.shapes.map(\.kind), [.image, .image])
        XCTAssertEqual(assets.map { $0.url.absoluteString }, [
            "https://pbs.twimg.com/media/one.jpg?name=orig",
            "https://pbs.twimg.com/media/two.jpg?name=orig",
        ])
    }

    /// The payloads the reader keeps. `note-tweet-long` is the sharp one: it
    /// carries a photo, so a plugin that did not decline would take a readable
    /// essay away from the reader and save its illustration instead.
    func testEveryPayloadTheReaderKeepsIsDeclined() async throws {
        for (fixture, id) in [
            ("x-note-tweet-long.json", "2081713721785631202"),
            ("x-long-form-article.json", "2082163285588107752"),
        ] {
            harness.fetcher.responses = [:]
            try serve(fixture, id: id)

            let assets = await harness.resolve(postURL(id))

            XCTAssertTrue(assets.isEmpty, fixture)
        }
    }

    /// A short text post carries nothing to download either way.
    func testShortTextPostResolvesNothing() async throws {
        let id = "2074973674332123157"
        try serve("x-standalone-short.json", id: id)

        let assets = await harness.resolve(postURL(id))
        XCTAssertTrue(assets.isEmpty)
    }

    /// The v1 single-post route answers when the v2 thread route is
    /// unavailable.
    func testFallsBackToTheSinglePostRouteWhenTheThreadRouteFails() async throws {
        let id = "2082319924987351577"
        harness.fetcher.respond(
            to: "https://api.fxtwitter.com/status/\(id)",
            body: try MediaPluginHarness.fixture("x/x-gif-post.json"))

        let assets = await harness.resolve(postURL(id))

        XCTAssertEqual(assets.shapes.map(\.kind), [.video])
        XCTAssertEqual(harness.fetcher.requests.map { $0.url.absoluteString }, [
            "https://api.fxtwitter.com/2/thread/\(id)",
            "https://api.fxtwitter.com/status/\(id)",
        ])
    }

    /// Only a numeric status claims. A profile and a non-numeric path do not,
    /// so `twitter.com/home` never reaches the mirror.
    func testOnlyANumericStatusIsClaimed() async {
        let status = await harness.classify("https://twitter.com/someone/status/12345")
        XCTAssertEqual(status, .claimed(kind: .media, itemID: "12345", confidence: nil))
        for url in [
            "https://x.com/someone",
            "https://x.com/home",
            "https://x.com/someone/status/not-a-number",
        ] {
            let verdict = await harness.classify(url)
            XCTAssertEqual(verdict, .declined, url)
        }
    }
}

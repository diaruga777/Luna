//
//  RedditPluginTests.swift
//  LunaTests
//

import LunaModels
import XCTest

/// `reddit.js` against the listing payloads `RedditMediaParserTests` reads, and
/// against the Swift resolver the Downloader app still runs.
final class RedditPluginTests: XCTestCase {

    private var harness: MediaPluginHarness!

    private static let postURL = "https://www.reddit.com/r/videos/comments/abc123/title/"
    private static let listingURL = "https://www.reddit.com/comments/abc123.json"

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try MediaPluginHarness("reddit", id: "app.luna.reddit")
    }

    override func tearDown() {
        harness.cleanUp()
        harness = nil
        super.tearDown()
    }

    private func fixture(_ name: String) throws -> String {
        try MediaPluginHarness.fixture("reddit/\(name)")
    }

    /// Both engines resolve the same asset from the same listing: the video,
    /// its derived audio leg, the DASH manifest and the thumbnail.
    func testEveryListingResolvesTheSameAssetAsTheSwiftResolver() async throws {
        let cases = [
            "silent-video.json", "video-with-audio.json", "crosspost.json", "image-post.json",
        ]
        for name in cases {
            let body = try fixture(name)
            harness.fetcher.responses = [:]
            harness.fetcher.respond(to: Self.listingURL, body: body)

            let plugin = await harness.resolve(Self.postURL)
            let swift = await swiftResolvedAssets(
                for: Self.postURL, answering: [(needle: "comments/abc123.json", body: body)])

            XCTAssertEqual(plugin.shapes, swift.shapes, name)
        }
    }

    /// The audio companion is the sibling `audio` path, not a `DASH_audio.mp4`
    /// filename — the name Reddit's own manifest gives it.
    func testVideoWithSoundCarriesTheSiblingAudioPath() async throws {
        harness.fetcher.respond(
            to: Self.listingURL, body: try fixture("video-with-audio.json"))

        let assets = await harness.resolve(Self.postURL)

        XCTAssertEqual(assets.count, 1)
        XCTAssertEqual(
            assets.first?.audioURL?.absoluteString, "https://v.redd.it/abc123def456/audio")
        XCTAssertEqual(
            assets.first?.dashManifestURL?.absoluteString,
            "https://v.redd.it/abc123def456/DASHPlaylist.mpd?a=1")
        XCTAssertEqual(assets.first?.quality, "1080p")
    }

    /// A post with no hosted video resolves nothing, so the walk falls through
    /// to the Swift classifier rather than saving a link as media.
    func testImagePostResolvesNothing() async throws {
        harness.fetcher.respond(to: Self.listingURL, body: try fixture("image-post.json"))

        let assets = await harness.resolve(Self.postURL)

        XCTAssertTrue(assets.isEmpty)
    }

    /// Every permalink shape a Reddit POST can take is claimed, and a feed is
    /// not: a subreddit named "comments" and a bare comment history are listings.
    func testOnlyPostPermalinksAreClaimed() async {
        let claimed: [(String, String)] = [
            ("https://www.reddit.com/r/videos/comments/abc123/title/", "abc123"),
            ("https://www.reddit.com/comments/abc123", "abc123"),
            ("https://www.reddit.com/user/someone/comments/xyz789/title/", "xyz789"),
            ("https://www.reddit.com/gallery/g12345", "g12345"),
            ("https://redd.it/short99", "short99"),
        ]
        for (url, expected) in claimed {
            let verdict = await harness.classify(url)
            XCTAssertEqual(verdict, .claimed(kind: .media, itemID: expected, confidence: nil), url)
        }
        for url in [
            "https://www.reddit.com/r/comments/top/",
            "https://www.reddit.com/user/someone/comments/",
            "https://www.reddit.com/",
        ] {
            let verdict = await harness.classify(url)
            XCTAssertEqual(verdict, .declined, url)
        }
    }

    /// An app-native share link carries no post id. It is claimed with none, and
    /// the redirect the fetch follows names the post.
    func testShareLinkIsClaimedWithoutAnIDAndResolvedByItsRedirect() async throws {
        let shareURL = "https://www.reddit.com/r/videos/s/Ab9Xk2Qz"
        let verdict = await harness.classify(shareURL)
        XCTAssertEqual(verdict, .claimed(kind: .media, itemID: nil, confidence: nil))
        harness.fetcher.respond(
            to: shareURL, body: "",
            finalURL: "https://www.reddit.com/r/videos/comments/abc123/title/")
        harness.fetcher.respond(
            to: Self.listingURL, body: try fixture("silent-video.json"))

        let assets = await harness.resolve(shareURL)

        XCTAssertEqual(
            assets.first?.url.absoluteString,
            "https://v.redd.it/abc123def456/DASH_720.mp4?source=fallback")
    }
}

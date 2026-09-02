//
//  InstagramPluginTests.swift
//  LunaTests
//

import LunaModels
import LunaPluginKit
import XCTest

/// `instagram.js` over the three-stage ladder, against the payloads
/// `SocialMediaResolverTests` reads and against the Swift resolver itself.
///
/// The rule every case is really about: a source that says "this is a video"
/// without naming a playable URL must not fall through to a still. That still is
/// the reel's cover frame, and saving it is how a reel came back as an image.
final class InstagramPluginTests: XCTestCase {

    private var harness: MediaPluginHarness!

    private static let shortcode = "DbripgRKlb_"
    private static let reelURL = "https://www.instagram.com/jonfilipko/reel/DbripgRKlb_/"
    private static let crawlerURL = "https://www.instagram.com/p/DbripgRKlb_/"
    private static let graphQLURL =
        "https://www.instagram.com/graphql/query/?doc_id=10015901848480474"
        + "&variables=%7B%22shortcode%22%3A%22DbripgRKlb_%22%7D"
    private static let embedURL =
        "https://www.instagram.com/p/DbripgRKlb_/embed/captioned/"

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try MediaPluginHarness("instagram", id: "app.luna.instagram")
    }

    override func tearDown() {
        harness.cleanUp()
        harness = nil
        super.tearDown()
    }

    private func fixture(_ name: String) throws -> String {
        try MediaPluginHarness.fixture("instagram/\(name)")
    }

    // MARK: - The crawler post page

    /// The leading stage, and today the only keyless source that still carries a
    /// reel's playable URL. Both engines read the same node.
    func testCrawlerPageResolvesTheReelAndAgreesWithTheSwiftResolver() async throws {
        let body = try fixture("crawler-reel.html")
        harness.fetcher.respond(to: Self.crawlerURL, body: body)

        let plugin = await harness.resolve(Self.reelURL)
        let swift = await swiftResolvedAssets(
            for: Self.reelURL, answering: [(needle: "/p/\(Self.shortcode)/", body: body)])

        XCTAssertEqual(plugin.shapes, swift.shapes)
        XCTAssertEqual(plugin.first?.kind, .video)
        XCTAssertEqual(plugin.first?.url.absoluteString, "https://video.example.com/reel.mp4")
        XCTAssertEqual(
            plugin.first?.thumbnailURL?.absoluteString, "https://cdn.example.com/cover-frame.jpg")
        XCTAssertEqual(plugin.first?.quality, "1080p")
    }

    /// It asks the crawler-served page first, cookie-free, and nothing else when
    /// that page answers.
    func testTheCrawlerPageIsTheFirstAndOnlyRequestWhenItAnswers() async throws {
        harness.fetcher.respond(to: Self.crawlerURL, body: try fixture("crawler-reel.html"))

        _ = await harness.resolve(Self.reelURL)

        XCTAssertEqual(harness.fetcher.requests.count, 1)
        let request = harness.fetcher.requests.first
        XCTAssertEqual(request?.url.absoluteString, Self.crawlerURL)
        XCTAssertEqual(request?.cookies, PluginFetchRequest.CookiePolicy.none)
        XCTAssertTrue(request?.headers["User-Agent"]?.contains("Googlebot") ?? false)
    }

    /// A carousel resolves every child, in post order, from `carousel_media`.
    func testCrawlerCarouselResolvesEveryChildInOrder() async throws {
        let body = try fixture("crawler-carousel.html")
        harness.fetcher.respond(to: Self.crawlerURL, body: body)

        let plugin = await harness.resolve(Self.reelURL)
        let swift = await swiftResolvedAssets(
            for: Self.reelURL, answering: [(needle: "/p/\(Self.shortcode)/", body: body)])

        XCTAssertEqual(plugin.shapes, swift.shapes)
        XCTAssertEqual(plugin.map(\.kind), [.image, .video])
        XCTAssertEqual(plugin.map { $0.url.absoluteString }, [
            "https://cdn.example.com/one.jpg", "https://video.example.com/two.mp4",
        ])
    }

    /// A page with no logged-out media node lets the ladder carry on.
    func testAPageWithNoMediaNodeFallsThroughToTheQuery() async throws {
        harness.fetcher.respond(to: Self.crawlerURL, body: try fixture("crawler-gated.html"))
        harness.fetcher.respond(to: Self.graphQLURL, body: try fixture("graphql-reel.json"))

        let assets = await harness.resolve(Self.reelURL)

        XCTAssertEqual(assets.first?.url.absoluteString, "https://video.example.com/reel.mp4")
    }

    // MARK: - The persisted GraphQL query

    /// The second stage answers the moment Instagram's login wall lifts, and it
    /// asks with the shortcode the URL named.
    func testGraphQLQueryResolvesTheReelWithItsPoster() async throws {
        let body = try fixture("graphql-reel.json")
        harness.fetcher.respond(to: Self.crawlerURL, status: 401, body: "")
        harness.fetcher.respond(to: Self.graphQLURL, body: body)

        let plugin = await harness.resolve(Self.reelURL)
        let swift = await swiftResolvedAssets(for: Self.reelURL, answering: [
            (needle: "/graphql/query/", body: body),
        ])

        XCTAssertEqual(plugin.shapes, swift.shapes)
        XCTAssertEqual(plugin.first?.url.absoluteString, "https://video.example.com/reel.mp4")
        XCTAssertEqual(
            plugin.first?.thumbnailURL?.absoluteString, "https://cdn.example.com/cover-frame.jpg")
    }

    func testGraphQLCarouselResolvesEveryChildInOrder() async throws {
        let body = try fixture("graphql-carousel.json")
        harness.fetcher.respond(to: Self.crawlerURL, status: 401, body: "")
        harness.fetcher.respond(to: Self.graphQLURL, body: body)

        let plugin = await harness.resolve(Self.reelURL)
        let swift = await swiftResolvedAssets(for: Self.reelURL, answering: [
            (needle: "/graphql/query/", body: body),
        ])

        XCTAssertEqual(plugin.shapes, swift.shapes)
        XCTAssertEqual(plugin.map(\.kind), [.image, .video])
    }

    /// A photo post is unaffected by the login wall.
    func testPhotoPostResolvesAsAnImage() async throws {
        harness.fetcher.respond(to: Self.crawlerURL, status: 401, body: "")
        harness.fetcher.respond(to: Self.graphQLURL, body: try fixture("graphql-photo.json"))

        let assets = await harness.resolve(Self.reelURL)

        XCTAssertEqual(assets.map(\.kind), [.image])
        XCTAssertEqual(assets.first?.url.absoluteString, "https://cdn.example.com/photo.jpg")
    }

    // MARK: - The declared-video guard

    /// Every source that says "video" without a playable URL. The ladder must
    /// end with nothing rather than with a cover frame, whichever source said it.
    func testAVideoWithNoPlayableURLNeverResolvesToItsStill() async throws {
        let ladders: [(String, [(String, String)])] = [
            ("the query", [
                (Self.crawlerURL, "walled.html"),
                (Self.graphQLURL, "graphql-video-no-url.json"),
                (Self.embedURL, "embed-photo.html"),
                (Self.reelURL, "og-still.html"),
            ]),
            ("the crawler page", [
                (Self.crawlerURL, "crawler-video-no-url.html"),
                (Self.graphQLURL, "walled.html"),
                (Self.embedURL, "walled.html"),
                (Self.reelURL, "og-still.html"),
            ]),
            ("the embed", [
                (Self.crawlerURL, "walled.html"),
                (Self.graphQLURL, "walled.html"),
                (Self.embedURL, "embed-video-no-url.html"),
                (Self.reelURL, "og-still.html"),
            ]),
        ]
        for (name, table) in ladders {
            harness.fetcher.responses = [:]
            for (url, fixtureName) in table {
                harness.fetcher.respond(to: url, body: try fixture(fixtureName))
            }

            let assets = await harness.resolve(Self.reelURL)

            XCTAssertTrue(assets.isEmpty, "\(name) declared a video and a still was saved")
        }
    }

    /// The query's "video, no playable URL" answer STOPS the ladder: the sources
    /// below can only offer the poster, so they are never asked.
    func testTheQueryDeclaringAVideoStopsTheLadder() async throws {
        harness.fetcher.respond(to: Self.crawlerURL, body: try fixture("walled.html"))
        harness.fetcher.respond(to: Self.graphQLURL, body: try fixture("graphql-video-no-url.json"))

        _ = await harness.resolve(Self.reelURL)

        XCTAssertEqual(harness.fetcher.requests.count, 2)
    }

    // MARK: - The embed page

    func testEmbedPageResolvesTheReelWhenTheSourcesAboveAreWalled() async throws {
        harness.fetcher.respond(to: Self.crawlerURL, body: try fixture("walled.html"))
        harness.fetcher.respond(to: Self.graphQLURL, body: try fixture("walled.html"))
        harness.fetcher.respond(to: Self.embedURL, body: try fixture("embed-reel.html"))

        let assets = await harness.resolve(Self.reelURL)

        XCTAssertEqual(assets.first?.url.absoluteString, "https://video.example.com/reel.mp4")
        XCTAssertEqual(assets.first?.thumbnailURL?.absoluteString, "https://cdn.example.com/reel.jpg")
    }

    /// Every post-path shape claims, and a profile does not.
    func testOnlyAPostPathIsClaimed() async {
        for url in [
            "https://www.instagram.com/p/AbCdEfGhIjK/",
            "https://www.instagram.com/reel/AbCdEfGhIjK/",
            "https://www.instagram.com/reels/AbCdEfGhIjK/",
            "https://www.instagram.com/tv/AbCdEfGhIjK/",
            "https://www.instagram.com/someone/reel/AbCdEfGhIjK/",
        ] {
            let verdict = await harness.classify(url)
            XCTAssertEqual(
                verdict, .claimed(kind: .media, itemID: "AbCdEfGhIjK", confidence: nil), url)
        }
        let profile = await harness.classify("https://www.instagram.com/someone/")
        XCTAssertEqual(profile, .declined)
    }
}

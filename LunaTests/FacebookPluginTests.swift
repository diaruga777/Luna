//
//  FacebookPluginTests.swift
//  LunaTests
//

import LunaModels
import LunaPluginKit
import XCTest

/// `facebook.js` over its four stages, against the pages
/// `SocialMediaResolverTests` reads and against the Swift resolver the
/// Downloader app still runs.
///
/// The rule under every case: `og:image` is a poster, never downloadable media.
/// A stage that finds only a poster carries on to the next.
final class FacebookPluginTests: XCTestCase {

    private var harness: MediaPluginHarness!

    private static let reelURL =
        "https://www.facebook.com/reel/1661338298308685/?fs=e&mibextid=wwXIfr&fs=e"
    private static let stableReelURL = "https://www.facebook.com/reel/1661338298308685/"
    private static let watchURL = "https://www.facebook.com/watch/?v=3928133123988446"

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try MediaPluginHarness("facebook", id: "app.luna.facebook")
    }

    override func tearDown() {
        harness.cleanUp()
        harness = nil
        super.tearDown()
    }

    private func fixture(_ name: String) throws -> String {
        try MediaPluginHarness.fixture("facebook/\(name)")
    }

    /// The embed URL the plugin builds. `encodeURIComponent` leaves the
    /// unreserved marks alone, so the allowed set is spelled out rather than
    /// borrowed from a Foundation preset.
    private func embedURL(for url: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return "https://www.facebook.com/plugins/video.php?href="
            + url.addingPercentEncoding(withAllowedCharacters: allowed)!
    }

    /// The video embed is the first request, HD wins over SD, and the tracking
    /// query never reaches it.
    func testTheVideoPluginEmbedIsAskedFirstWithTheCleanPermalink() async throws {
        let body = try fixture("plugin-embed-hd.html")
        harness.fetcher.respond(to: embedURL(for: Self.stableReelURL), body: body)

        let plugin = await harness.resolve(Self.reelURL)
        let swift = await swiftResolvedAssets(for: Self.reelURL, answering: [
            (needle: "plugins/video.php", body: body),
        ])

        XCTAssertEqual(plugin.shapes, swift.shapes)
        XCTAssertEqual(plugin.first?.url.absoluteString, "https://video.example.com/reel-hd.mp4")
        XCTAssertEqual(harness.fetcher.requests.count, 1)
        let request = harness.fetcher.requests.first
        XCTAssertTrue(request?.url.absoluteString.contains("plugins/video.php") ?? false)
        XCTAssertTrue(request?.headers["User-Agent"]?.contains("Macintosh") ?? false)
        XCTAssertEqual(request?.cookies, PluginFetchRequest.CookiePolicy.none)
        XCTAssertFalse(request?.url.absoluteString.contains("mibextid") ?? true)
    }

    /// The inline JSON's escaped URL is unescaped the same way by both engines.
    func testInlinePlayableURLIsUnescapedAndBeatsThePoster() async throws {
        let body = try fixture("inline-hd.html")
        harness.fetcher.respond(to: embedURL(for: Self.watchURL), body: body)

        let plugin = await harness.resolve(Self.watchURL)
        let swift = await swiftResolvedAssets(for: Self.watchURL, answering: [
            (needle: "plugins/video.php", body: body),
        ])

        XCTAssertEqual(plugin.shapes, swift.shapes)
        XCTAssertEqual(
            plugin.first?.url.absoluteString,
            "https://video.example.com/hd.mp4?token=one&encoded=yes%3D%3D")
        XCTAssertEqual(
            plugin.first?.thumbnailURL?.absoluteString, "https://cdn.example.com/poster.jpg")
    }

    /// A page carrying only `og:image` resolves nothing, at every stage, so a
    /// video never saves its poster.
    func testAPosterOnlyPageResolvesNothing() async throws {
        let body = try fixture("poster-only.html")
        for url in [embedURL(for: Self.watchURL), Self.watchURL] {
            harness.fetcher.respond(to: url, body: body)
        }

        let plugin = await harness.resolve(Self.watchURL)
        let swift = await swiftResolvedAssets(
            for: Self.watchURL, answering: [(needle: "facebook.com", body: body)])

        XCTAssertTrue(plugin.isEmpty)
        XCTAssertEqual(plugin.shapes, swift.shapes)
    }

    /// `og:video` is the last resort, and the attribute order Facebook varies
    /// does not change the answer.
    func testOpenGraphVideoResolvesWhenNoInlineJSONDoes() async throws {
        let cases = [
            ("og-video-only.html", "https://video.example.com/clip.mp4?x=1&y=2"),
            ("mobile-attribute-order.html", "https://video.example.com/reel.mp4?x=1&y=2"),
        ]
        for (name, expected) in cases {
            harness.fetcher.responses = [:]
            let body = try fixture(name)
            harness.fetcher.respond(to: embedURL(for: Self.watchURL), body: body)

            let plugin = await harness.resolve(Self.watchURL)
            let swift = await swiftResolvedAssets(for: Self.watchURL, answering: [
                (needle: "plugins/video.php", body: body),
            ])

            XCTAssertEqual(plugin.first?.url.absoluteString, expected, name)
            XCTAssertEqual(plugin.shapes, swift.shapes, name)
        }
    }

    /// A `/reel/` link 400s on the desktop agent, so the mobile page's own
    /// `og:video` is the reel's only asset. Its canonical is the reel itself,
    /// which makes canonical resolution a no-op.
    func testReelFallsBackToTheMobilePageOpenGraphVideo() async throws {
        let body = try fixture("mobile-reel.html")
        harness.fetcher.respond(to: Self.stableReelURL, body: body)

        let plugin = await harness.resolve(Self.reelURL)
        let swift = await swiftResolvedAssets(for: Self.reelURL, answering: [
            (needle: "plugins/video.php", body: ""),
            (needle: "facebook.com", body: body),
        ])

        XCTAssertEqual(
            plugin.first?.url.absoluteString, "https://video.example.com/reel.mp4?x=1&y=2")
        XCTAssertEqual(
            plugin.first?.thumbnailURL?.absoluteString, "https://cdn.example.com/poster.jpg")
        XCTAssertEqual(plugin.shapes, swift.shapes)
    }

    /// A short link's page exposes the canonical long-form video URL; that page
    /// is then read with the desktop agent for its inline JSON.
    func testShortLinkResolvesItsCanonicalVideoPage() async throws {
        let shortURL = "https://fb.watch/IerlpQvlv-/?mibextid=wwXIfr"
        let stable = "https://fb.watch/IerlpQvlv-/"
        let canonical =
            "https://www.facebook.com/TheOnion/videos/a-story/3928133123988446/"
        harness.fetcher.respond(to: embedURL(for: stable), body: try fixture("login-wall.html"))
        harness.fetcher.respond(to: stable, body: try fixture("mobile-canonical-only.html"))
        harness.fetcher.respond(to: canonical, body: try fixture("canonical-inline.html"))

        let assets = await harness.resolve(shortURL)

        XCTAssertEqual(
            assets.first?.url.absoluteString, "https://video.example.com/fbwatch.mp4")
        XCTAssertTrue(harness.fetcher.requests.contains {
            $0.url.absoluteString == canonical
                && ($0.headers["User-Agent"]?.contains("Macintosh") ?? false)
        })
    }

    /// The crawler unfurl is the last stage, and it is reached only after the
    /// three page stages have found nothing.
    func testTheCrawlerUnfurlIsTheLastStageAsked() async throws {
        let shell = try fixture("login-wall.html")
        harness.fetcher.respond(to: embedURL(for: Self.stableReelURL), body: shell)
        harness.fetcher.respond(to: Self.stableReelURL, body: shell)

        let assets = await harness.resolve(Self.reelURL)

        XCTAssertTrue(assets.isEmpty)
        XCTAssertEqual(harness.fetcher.requests.count, 4)
        XCTAssertTrue(
            harness.fetcher.requests.last?.headers["User-Agent"]?
                .contains("facebookexternalhit") ?? false)
    }

    /// Every Facebook URL is claimed; the id comes from `?v=` or the path.
    func testTheItemIDComesFromTheQueryOrThePath() async {
        let watch = await harness.classify(Self.watchURL)
        XCTAssertEqual(watch, .claimed(kind: .media, itemID: "3928133123988446", confidence: nil))
        let reel = await harness.classify(Self.reelURL)
        XCTAssertEqual(reel, .claimed(kind: .media, itemID: "1661338298308685", confidence: nil))
        let short = await harness.classify("https://fb.watch/IerlpQvlv-/")
        XCTAssertEqual(short, .claimed(kind: .media, itemID: nil, confidence: nil))
    }
}

//
//  YouTubePluginTests.swift
//  LunaTests
//

import LunaModels
import XCTest

/// `youtube.js` over the guest-session handshake, against the payloads
/// `SocialMediaResolverTests` reads and against the Swift resolver the
/// Downloader app still runs.
///
/// The handshake is the whole point: Google's video servers refuse the watch
/// page's own progressive URL without a Proof-of-Origin token, so the plugin
/// establishes a guest session, reads the active player's signature timestamp
/// and asks the ANDROID_VR client, which needs neither.
final class YouTubePluginTests: XCTestCase {

    private var harness: MediaPluginHarness!

    private static let videoID = "bcHXFQIZ4lY"
    private static let shortURL = "https://youtube.com/shorts/bcHXFQIZ4lY?si=reported"
    private static let watchURL =
        "https://www.youtube.com/watch?v=bcHXFQIZ4lY&bpctr=9999999999&has_verified=1"
    private static let playerJSURL =
        "https://www.youtube.com/s/player/hash/player_es6.vflset/en_US/base.js"
    private static let androidVRURL =
        "https://www.youtube.com/youtubei/v1/player?prettyPrint=false"
    private static let embedURL = "https://www.youtube.com/embed/bcHXFQIZ4lY?html5=1"

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try MediaPluginHarness("youtube", id: "app.luna.youtube")
    }

    override func tearDown() {
        harness.cleanUp()
        harness = nil
        super.tearDown()
    }

    private func fixture(_ name: String) throws -> String {
        try MediaPluginHarness.fixture("youtube/\(name)")
    }

    /// Serves the three legs of the handshake.
    private func serveHandshake(player: String = "android-vr-player.json") throws {
        harness.fetcher.respond(to: Self.watchURL, body: try fixture("watch-bootstrap.html"))
        harness.fetcher.respond(to: Self.playerJSURL, body: try fixture("player-js.js"))
        harness.fetcher.respond(to: Self.androidVRURL, body: try fixture(player))
    }

    private func swiftAnswers(player: String) throws -> [(needle: String, body: String)] {
        [
            (needle: "/s/player/", body: try fixture("player-js.js")),
            (needle: "/youtubei/v1/player", body: try fixture(player)),
            (needle: "/watch", body: try fixture("watch-bootstrap.html")),
        ]
    }

    /// The whole handshake, and the same asset out of both engines.
    func testTheGuestBoundAndroidVRHandshakeResolvesTheStream() async throws {
        try serveHandshake()

        let plugin = await harness.resolve(Self.shortURL)
        let swift = await swiftResolvedAssets(
            for: Self.shortURL, answering: try swiftAnswers(player: "android-vr-player.json"))

        XCTAssertEqual(plugin.shapes, swift.shapes)
        XCTAssertEqual(
            plugin.first?.url.absoluteString,
            "https://video.example.com/youtube.mp4?expire=4102444800")
        XCTAssertEqual(plugin.first?.estimatedByteCount, 123_456)
        XCTAssertEqual(plugin.first?.quality, "640p")
    }

    /// Three requests, in order, and the player call carries the guest session,
    /// the client name and the timestamp the player JavaScript stated.
    func testThePlayerCallCarriesTheSessionAndTheSignatureTimestamp() async throws {
        try serveHandshake()

        _ = await harness.resolve(Self.shortURL)

        XCTAssertEqual(harness.fetcher.requests.map { $0.url.absoluteString }, [
            Self.watchURL, Self.playerJSURL, Self.androidVRURL,
        ])
        let player = try XCTUnwrap(harness.fetcher.requests.last)
        XCTAssertEqual(player.method, "POST")
        XCTAssertEqual(player.headers["X-YouTube-Client-Name"], "28")
        XCTAssertEqual(player.headers["X-Goog-Visitor-Id"], "CgtVisitor==")
        XCTAssertTrue(player.headers["User-Agent"]?.contains("youtube.vr.oculus") ?? false)
        let body = try XCTUnwrap(player.body)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["videoId"] as? String, Self.videoID)
        let playback = try XCTUnwrap(object["playbackContext"] as? [String: Any])
        let content = try XCTUnwrap(playback["contentPlaybackContext"] as? [String: Any])
        XCTAssertEqual(content["signatureTimestamp"] as? Int, 20_654)
    }

    /// The best progressive MP4 that carries sound wins: a taller adaptive
    /// video-only stream is skipped, because the engine downloads one file.
    func testTheBestProgressiveMP4WithSoundWins() async throws {
        try serveHandshake(player: "player-formats.json")

        let plugin = await harness.resolve(Self.shortURL)
        let swift = await swiftResolvedAssets(
            for: Self.shortURL, answering: try swiftAnswers(player: "player-formats.json"))

        XCTAssertEqual(plugin.shapes, swift.shapes)
        XCTAssertEqual(plugin.first?.url.absoluteString, "https://video.example.com/720.mp4")
        XCTAssertEqual(plugin.first?.estimatedByteCount, 30_000_000)
        XCTAssertEqual(
            plugin.first?.thumbnailURL?.absoluteString, "https://img.example.com/large.jpg")
    }

    /// A page commonly assigns `ytInitialPlayerResponse = null` before the real
    /// value. The scan must not stop at the first name, nor jump to an unrelated
    /// script's opening brace.
    func testTheWatchPageFallbackSkipsANullPlayerResponse() async throws {
        let body = try fixture("watch-null-then-real.html")
        harness.fetcher.respond(to: Self.watchURL, body: body)

        let plugin = await harness.resolve(Self.shortURL)
        let swift = await swiftResolvedAssets(
            for: Self.shortURL, answering: [(needle: "/watch", body: body)])

        XCTAssertEqual(plugin.shapes, swift.shapes)
        XCTAssertEqual(plugin.first?.url.absoluteString, "https://video.example.com/direct.mp4")
    }

    /// The embed page answers when the watch page carries nothing.
    func testTheEmbedPageIsAskedWhenTheWatchPageHasNoPlayerResponse() async throws {
        harness.fetcher.respond(to: Self.watchURL, body: try fixture("no-formats.html"))
        harness.fetcher.respond(to: Self.embedURL, body: try fixture("player-formats.json"))

        let assets = await harness.resolve(Self.shortURL)

        XCTAssertEqual(assets.first?.url.absoluteString, "https://video.example.com/720.mp4")
    }

    /// A clip URL holds neither its video nor its range; its own page names
    /// both, and the range rides the asset so the download is trimmed.
    func testAClipResolvesItsUnderlyingVideoAndRange() async throws {
        let clipURL = "https://www.youtube.com/clip/UgkxABCDEF"
        harness.fetcher.respond(to: clipURL, body: try fixture("clip-page.html"))
        harness.fetcher.respond(
            to: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&bpctr=9999999999&has_verified=1",
            body: try fixture("watch-bootstrap.html"))
        harness.fetcher.respond(to: Self.playerJSURL, body: try fixture("player-js.js"))
        harness.fetcher.respond(to: Self.androidVRURL, body: try fixture("player-formats.json"))

        let assets = await harness.resolve(clipURL)

        XCTAssertEqual(assets.first?.url.absoluteString, "https://video.example.com/720.mp4")
        XCTAssertEqual(
            assets.first?.timeRange, MediaTimeRange(startSeconds: 12.5, endSeconds: 28.75))
    }

    /// The timestamp forms a YouTube link can carry, and the range each one
    /// means. A start with no end trims from that second to the source end.
    func testEveryTimestampFormResolvesTheRangeTheSwiftLinkParserReads() async throws {
        let cases: [(String, MediaTimeRange?)] = [
            ("https://youtu.be/dQw4w9WgXcQ?t=1m30s", MediaTimeRange(startSeconds: 90, endSeconds: nil)),
            ("https://m.youtube.com/watch?v=dQw4w9WgXcQ&start=45",
             MediaTimeRange(startSeconds: 45, endSeconds: nil)),
            ("https://www.youtube.com/shorts/dQw4w9WgXcQ#t=12s",
             MediaTimeRange(startSeconds: 12, endSeconds: nil)),
            ("https://youtube.com/watch?v=dQw4w9WgXcQ&t=5&end=15",
             MediaTimeRange(startSeconds: 5, endSeconds: 15)),
            ("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ", nil),
        ]
        for (url, expected) in cases {
            harness.fetcher.responses = [:]
            harness.fetcher.respond(
                to: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&bpctr=9999999999&has_verified=1",
                body: try fixture("watch-bootstrap.html"))
            harness.fetcher.respond(to: Self.playerJSURL, body: try fixture("player-js.js"))
            harness.fetcher.respond(
                to: Self.androidVRURL, body: try fixture("android-vr-player.json"))

            let plugin = await harness.resolve(url)
            let swift = await swiftResolvedAssets(
                for: url, answering: try swiftAnswers(player: "android-vr-player.json"))

            XCTAssertEqual(plugin.first?.timeRange, expected, url)
            XCTAssertEqual(plugin.shapes, swift.shapes, url)
        }
    }

    /// The stream URL's own `expire` becomes the Model's expiry, which is what
    /// makes the engine re-run this plugin instead of downloading a refusal.
    func testTheStreamExpiryRidesTheModel() async throws {
        try serveHandshake()

        let model = await harness.model(Self.shortURL)

        XCTAssertEqual(model?.expiresAt, Date(timeIntervalSince1970: 4_102_444_800))
        XCTAssertEqual(model?.platform, "youtube")
        XCTAssertEqual(model?.itemID, Self.videoID)
    }

    /// Every URL shape in the family names its video; a channel page does not.
    func testTheVideoIDIsReadFromEveryURLShape() async {
        for url in [
            "https://youtu.be/dQw4w9WgXcQ?si=abc",
            "https://m.youtube.com/watch?v=dQw4w9WgXcQ&start=45",
            "https://www.youtube.com/shorts/dQw4w9WgXcQ",
            "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ",
            "https://www.youtube.com/live/dQw4w9WgXcQ",
        ] {
            let verdict = await harness.classify(url)
            XCTAssertEqual(
                verdict, .claimed(kind: .media, itemID: "dQw4w9WgXcQ", confidence: nil), url)
        }
        let clip = await harness.classify("https://www.youtube.com/clip/UgkxABCDEF")
        XCTAssertEqual(clip, .claimed(kind: .media, itemID: nil, confidence: nil))
        let channel = await harness.classify("https://www.youtube.com/@someone")
        XCTAssertEqual(channel, .declined)
    }
}

//
//  YouTubeTranscriptPluginTests.swift
//  LunaTests
//

import LunaModels
import XCTest

/// `youtube-transcript.js` over the same guest-session handshake `youtube.js`
/// runs, reading the player response for the cheapest source of the spoken
/// words: a caption track, an audio-only stream, then the progressive MP4.
final class YouTubeTranscriptPluginTests: XCTestCase {

    private var harness: TranscriptPluginHarness!

    private static let videoID = "bcHXFQIZ4lY"
    private static let shortURL = "https://youtube.com/shorts/bcHXFQIZ4lY?si=reported"
    private static let watchURL =
        "https://www.youtube.com/watch?v=bcHXFQIZ4lY&bpctr=9999999999&has_verified=1"
    private static let playerJSURL =
        "https://www.youtube.com/s/player/hash/player_es6.vflset/en_US/base.js"
    private static let androidVRURL =
        "https://www.youtube.com/youtubei/v1/player?prettyPrint=false"
    private static let manualTimedTextURL =
        "https://www.youtube.com/api/timedtext?v=bcHXFQIZ4lY&lang=en&fmt=json3"

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try TranscriptPluginHarness(
            "youtube-transcript", id: "app.luna.youtube.transcript")
    }

    override func tearDown() {
        harness.cleanUp()
        harness = nil
        super.tearDown()
    }

    private func fixture(_ name: String) throws -> String {
        try MediaPluginHarness.fixture("youtube/\(name)")
    }

    private func serveHandshake(player: String) throws {
        harness.fetcher.respond(to: Self.watchURL, body: try fixture("watch-bootstrap.html"))
        harness.fetcher.respond(to: Self.playerJSURL, body: try fixture("player-js.js"))
        harness.fetcher.respond(to: Self.androidVRURL, body: try fixture(player))
    }

    /// Captions win: the manual track the default audio track points at is
    /// fetched as json3 and becomes paragraphs, and no file is offered.
    func testCaptionsBecomeTheArticleWithNoFileToTranscribe() async throws {
        try serveHandshake(player: "player-captions.json")
        harness.fetcher.respond(to: Self.manualTimedTextURL, body: try fixture("timedtext.json3"))

        let article = try await harness.requireArticle(Self.shortURL)

        XCTAssertNil(article.transcription)
        XCTAssertEqual(article.title, "Fixture talk")
        XCTAssertEqual(article.author, "Fixture Channel")
        XCTAssertEqual(article.language, "en")
        XCTAssertEqual(
            article.html,
            "<p>Welcome to the fixture talk. Today we test captions.</p>\n"
                + "<p>After a pause, a new paragraph &amp; an entity. Styled text ends here.</p>")
        XCTAssertTrue(
            harness.fetcher.requests.contains { $0.url.absoluteString == Self.manualTimedTextURL },
            "the manual track, not the asr one, is read")
    }

    /// With no captions, the highest-bitrate audio-only stream that has a plain
    /// URL is the source; a ciphered entry and a video-only stream are skipped.
    func testTheAudioOnlyStreamIsOfferedBeforeTheVideo() async throws {
        try serveHandshake(player: "player-adaptive-audio.json")

        let article = try await harness.requireArticle(Self.shortURL)
        let spec = try XCTUnwrap(article.transcription)

        XCTAssertEqual(spec.type.rawValue, "audio")
        XCTAssertEqual(
            spec.url.absoluteString, "https://video.example.com/audio-128k.m4a?expire=4102444800")
        XCTAssertEqual(spec.expiresAt, Date(timeIntervalSince1970: 4_102_444_800))
        XCTAssertEqual(spec.headers["Referer"], "https://www.youtube.com/")
        XCTAssertEqual(article.html, "<p>A synthetic description.</p>")
    }

    /// With neither captions nor an audio stream, the progressive MP4 with
    /// sound — the file `youtube.js` would download — is the source.
    func testTheProgressiveVideoIsTheLastResort() async throws {
        try serveHandshake(player: "android-vr-player.json")

        let article = try await harness.requireArticle(Self.shortURL)
        let spec = try XCTUnwrap(article.transcription)

        XCTAssertEqual(spec.type.rawValue, "video")
        XCTAssertEqual(
            spec.url.absoluteString, "https://video.example.com/youtube.mp4?expire=4102444800")
        XCTAssertEqual(article.title, "YouTube \(Self.videoID)")
        XCTAssertTrue(article.html.isEmpty, "no description means no lead text")
    }

    /// A caption track whose fetch fails falls through to the file sources
    /// rather than failing the save.
    func testAnUnreadableCaptionTrackFallsThroughToTheFile() async throws {
        try serveHandshake(player: "player-captions.json")
        harness.fetcher.respond(to: Self.manualTimedTextURL, status: 404, body: "")

        let article = try await harness.requireArticle(Self.shortURL)

        XCTAssertEqual(article.transcription?.type.rawValue, "video")
    }

    /// Every URL shape in the family is claimed as an article; a clip and a
    /// channel page are not.
    func testTheURLFamilyIsClaimedAsAnArticle() async {
        for url in [
            "https://youtu.be/dQw4w9WgXcQ?si=abc",
            "https://m.youtube.com/watch?v=dQw4w9WgXcQ&start=45",
            "https://www.youtube.com/shorts/dQw4w9WgXcQ",
        ] {
            let verdict = await harness.classify(url)
            XCTAssertEqual(
                verdict, .claimed(kind: .article, itemID: "dQw4w9WgXcQ", confidence: nil), url)
        }
        let clip = await harness.classify("https://www.youtube.com/clip/UgkxABCDEF")
        XCTAssertEqual(clip, .declined)
        let channel = await harness.classify("https://www.youtube.com/@someone")
        XCTAssertEqual(channel, .declined)
    }

    /// The media twin steps aside for a transcribe intent and still claims a
    /// plain save.
    func testTheMediaTwinDeclinesTheTranscribeIntent() async throws {
        try await assertMediaTwinDeclinesTranscribeIntent(
            "youtube", id: "app.luna.youtube", url: Self.shortURL)
    }
}

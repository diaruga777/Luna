//
//  TikTokPluginTests.swift
//  LunaTests
//

import LunaModels
import LunaPluginIngest
import XCTest

/// `tiktok.js` against the page variants `SocialMediaResolverTests` reads, and
/// against the Swift resolver the Downloader app still runs.
final class TikTokPluginTests: XCTestCase {

    private var harness: MediaPluginHarness!

    private static let postURL = "https://www.tiktok.com/@someone/video/7123456789012345678"

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try MediaPluginHarness("tiktok", id: "app.luna.tiktok")
    }

    override func tearDown() {
        harness.cleanUp()
        harness = nil
        super.tearDown()
    }

    /// Every page variant resolves the same asset in both engines. The
    /// `api-data` route is the one a background fetch actually gets; missing it
    /// is what made every TikTok save report "couldn't find media to download".
    func testEveryPageVariantResolvesTheSameAssetAsTheSwiftResolver() async throws {
        let cases: [(String, [String])] = [
            ("rehydration-video.html", ["https://video.example.com/tiktok.mp4"]),
            ("reflow-video.html", ["https://video.example.com/reflow.mp4"]),
            ("reflow-download-addr.html", ["https://video.example.com/download.mp4"]),
            ("api-data-video.html", ["https://video.example.com/apidata.mp4"]),
            ("prefers-rehydration.html", ["https://video.example.com/shell.mp4"]),
            ("script-src-decoy.html", ["https://video.example.com/real.mp4"]),
            ("api-data-photo-carousel.html", [
                "https://cdn.example.com/one.jpg", "https://cdn.example.com/two.jpg",
            ]),
            ("no-payload.html", []),
        ]
        for (name, expected) in cases {
            let body = try MediaPluginHarness.fixture("tiktok/\(name)")
            harness.fetcher.responses = [:]
            harness.fetcher.respond(to: Self.postURL, body: body)

            let plugin = await harness.resolve(Self.postURL)
            let swift = await swiftResolvedAssets(
                for: Self.postURL, answering: [(needle: "tiktok.com", body: body)])

            XCTAssertEqual(plugin.map { $0.url.absoluteString }, expected, name)
            XCTAssertEqual(plugin.shapes, swift.shapes, name)
        }
    }

    /// The cover frame rides the video as its poster.
    func testTheCoverFrameBecomesThePoster() async throws {
        harness.fetcher.respond(
            to: Self.postURL, body: try MediaPluginHarness.fixture("tiktok/api-data-video.html"))

        let assets = await harness.resolve(Self.postURL)

        XCTAssertEqual(
            assets.first?.thumbnailURL?.absoluteString, "https://cdn.example.com/cover.jpg")
    }

    /// A page the surface already read saves the round trip.
    func testAPageSnapshotIsUsedInsteadOfAFetch() async throws {
        let html = try MediaPluginHarness.fixture("tiktok/rehydration-video.html")

        let assets = await harness.resolve(
            Self.postURL,
            page: PluginPageSnapshot(url: Self.postURL, html: html, source: "fetch"))

        XCTAssertEqual(
            assets.first?.url.absoluteString, "https://video.example.com/tiktok.mp4")
        XCTAssertTrue(harness.fetcher.requests.isEmpty)
    }

    /// A snapshot with no payload in it still asks the page: the variant the
    /// surface captured is not always the variant that carries the item.
    func testASnapshotWithoutThePayloadStillAsksThePage() async throws {
        harness.fetcher.respond(
            to: Self.postURL,
            body: try MediaPluginHarness.fixture("tiktok/api-data-video.html"))

        let assets = await harness.resolve(
            Self.postURL,
            page: PluginPageSnapshot(
                url: Self.postURL,
                html: try MediaPluginHarness.fixture("tiktok/no-payload.html"),
                source: "fetch"))

        XCTAssertEqual(
            assets.first?.url.absoluteString, "https://video.example.com/apidata.mp4")
        XCTAssertEqual(harness.fetcher.requests.count, 1)
    }

    /// A numeric `/video/<id>` names the item; a short link claims without one,
    /// because only the page it lands on holds it.
    func testAShortLinkIsClaimedWithoutAnID() async {
        let post = await harness.classify(Self.postURL)
        XCTAssertEqual(post, .claimed(kind: .media, itemID: "7123456789012345678", confidence: nil))
        let short = await harness.classify("https://www.tiktok.com/t/ZP8Gqx5p5/")
        XCTAssertEqual(short, .claimed(kind: .media, itemID: nil, confidence: nil))
    }
}

//
//  XPostIngestProcessorTests.swift
//  LunaTests
//

import XCTest
import LunaFetch
import LunaIngest
import LunaModels
@testable import LunaArticleIngest

/// The processor (with its network leg injected) and the pipeline branch it feeds.
final class XPostIngestProcessorTests: XCTestCase {
    private let postURL = URL(string: "https://x.com/random_walker/status/2082163285588107752")!

    /// A processor whose fetch replays a recorded fixture, recording the endpoints
    /// it was asked for.
    private func processor(
        _ fixture: String?, endpoints: EndpointRecorder = EndpointRecorder()
    ) -> XPostIngestProcessor {
        XPostIngestProcessor { endpoint in
            endpoints.record(endpoint)
            guard let fixture else { return nil }
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/XPosts")
                .appendingPathComponent(fixture)
            return try? Data(contentsOf: url)
        }
    }

    final class EndpointRecorder {
        private(set) var requested: [String] = []
        func record(_ endpoint: String) { requested.append(endpoint) }
    }

    // MARK: - The processor

    func testLongPostBecomesAnArticleWithRenderedHTML() async throws {
        let read = await processor("x-article.json")
            .article(platform: .x, itemID: "1", url: postURL)
        let result = try XCTUnwrap(read)
        XCTAssertEqual(
            result.content.title, "What's gone wrong with AI & labor — a thought experiment")
        // The html half must be real: the artifact stages read an og:image from it
        // and archive it, and an empty string would send the archiver to x.com.
        XCTAssertTrue(result.html.contains("og:title"))
        XCTAssertTrue(result.html.contains("<article>"))
        XCTAssertFalse(result.html.isEmpty)
    }

    func testShortPostIsDeclined() async {
        let result = await processor("standalone-short.json")
            .article(platform: .x, itemID: "1", url: postURL)
        XCTAssertNil(result)
    }

    /// The thread route is tried FIRST, because it covers the single-post and
    /// chained cases in one call.
    func testThreadEndpointIsPreferred() async {
        let endpoints = EndpointRecorder()
        _ = await processor("x-article.json", endpoints: endpoints)
            .article(platform: .x, itemID: "42", url: postURL)
        XCTAssertEqual(endpoints.requested.first, "https://api.fxtwitter.com/2/thread/42")
    }

    /// A well-formed but too-short payload is a definitive no — the v1 fallback
    /// would return the same post, so a short post must cost ONE request.
    func testShortPostDoesNotRetryTheFallbackEndpoint() async {
        let endpoints = EndpointRecorder()
        _ = await processor("standalone-short.json", endpoints: endpoints)
            .article(platform: .x, itemID: "42", url: postURL)
        XCTAssertEqual(endpoints.requested.count, 1)
    }

    /// An unreachable API falls back to the v1 route, then gives up quietly.
    func testUnreachableAPITriesBothRoutesThenDeclines() async {
        let endpoints = EndpointRecorder()
        let result = await processor(nil, endpoints: endpoints)
            .article(platform: .x, itemID: "42", url: postURL)
        XCTAssertNil(result)
        XCTAssertEqual(endpoints.requested, [
            "https://api.fxtwitter.com/2/thread/42",
            "https://api.fxtwitter.com/status/42",
        ])
    }

    /// Other social platforms are not handled here and must cost no request.
    func testNonXPlatformsAreDeclinedWithoutFetching() async {
        for platform in [ContentPlatform.bluesky, .reddit, .instagram] {
            let endpoints = EndpointRecorder()
            let result = await processor("x-article.json", endpoints: endpoints)
                .article(platform: platform, itemID: "1", url: postURL)
            XCTAssertNil(result, "\(platform) should not be read as an X post")
            XCTAssertTrue(endpoints.requested.isEmpty)
        }
    }

    /// A platform URL with no post id (a bare profile) has no text to read.
    func testMissingOrNonNumericItemIDIsDeclinedWithoutFetching() async {
        for itemID in [nil, "", "not-an-id"] as [String?] {
            let endpoints = EndpointRecorder()
            let result = await processor("x-article.json", endpoints: endpoints)
                .article(platform: .x, itemID: itemID, url: postURL)
            XCTAssertNil(result)
            XCTAssertTrue(endpoints.requested.isEmpty)
        }
    }

    // MARK: - The pipeline branch

    /// A stub standing in for the registered processor.
    private struct StubSocialText: SocialTextIngestProcessing {
        let stubbed: ArticleContent?
        func article(
            platform: ContentPlatform, itemID: String?, url: URL
        ) async -> SocialTextArticle? {
            stubbed.map { SocialTextArticle(content: $0, html: "<html></html>") }
        }
    }

    /// Runs the pipeline over the X post URL. The mock fetcher is empty, and the
    /// tests assert it was never consulted: an X post's text comes from the API,
    /// never from scraping x.com.
    private func outcome(
        socialText: SocialTextIngestProcessing?, fetcher: MockArticleFetcher = MockArticleFetcher()
    ) async -> Outcome {
        await IngestPipeline.process(
            IngestInput(url: postURL, source: .shareSheet),
            fetcher: fetcher, articleProcessor: nil, productProcessor: nil,
            socialTextProcessor: socialText)
    }

    /// A long-form post is rerouted to `.article`, which makes it Reader-owned.
    func testLongPostIsReroutedToArticle() async {
        let content = ArticleContent(
            title: "A long post", blocks: [.init(kind: .paragraph, text: "Body", links: [])])
        let fetcher = MockArticleFetcher()
        let outcome = await outcome(socialText: StubSocialText(stubbed: content), fetcher: fetcher)
        guard case let .article(returned, html) = outcome else {
            return XCTFail("expected .article, got \(outcome)")
        }
        XCTAssertEqual(returned.title, "A long post")
        XCTAssertEqual(html, "<html></html>")
        XCTAssertEqual(outcome.owningApp, .reader)
        XCTAssertTrue(fetcher.calls.isEmpty, "the X text path must never fetch x.com")
    }

    /// A declined post keeps the pre-existing behavior exactly: `.social`, owned
    /// by the Downloader.
    func testDeclinedPostStaysSocial() async {
        let fetcher = MockArticleFetcher()
        let outcome = await outcome(socialText: StubSocialText(stubbed: nil), fetcher: fetcher)
        XCTAssertEqual(outcome, .social(.x, itemID: "2082163285588107752"))
        XCTAssertEqual(outcome.owningApp, .downloader)
        XCTAssertTrue(fetcher.calls.isEmpty)
    }

    /// An app that registers no processor (Downloader / Price Tracker) is
    /// unaffected — the X link classifies exactly as it did before this seam.
    func testUnregisteredProcessorLeavesClassificationUnchanged() async {
        let outcome = await outcome(socialText: nil)
        XCTAssertEqual(outcome, .social(.x, itemID: "2082163285588107752"))
    }
}

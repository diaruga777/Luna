//
//  IngestPipelineTests.swift
//  ClipTests
//

import ClipIngest
import ClipFetch
import ClipModels
import XCTest
@testable import Clip

/// Exercises the ONE shared `IngestPipeline.process` that every surface calls. The
/// headline guarantee is PARITY: the SAME `IngestInput` (varying only `source`)
/// yields the SAME `Outcome` across all sources, because there's one pipeline.
/// Also covers: platform/video URLs classified before any extraction (never an
/// article), product/article/paywalled classification, and the mandatory overall
/// timeout (a slow mock resolves to `.failed`/`.needsArchive` within the deadline —
/// it can never hang). Network-free (a mock `HTMLFetching`).
final class IngestPipelineTests: XCTestCase {

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else { fatalError("bad test URL: \(string)") }
        return url
    }

    private func readableHTML() -> String {
        let paragraph = "<p>" + String(repeating: "An ordinary readable sentence about the topic. ", count: 30) + "</p>"
        return "<html><head><title>Real Story</title></head><body><article>\(paragraph)\(paragraph)</article></body></html>"
    }

    private func lockedHTML() -> String {
        "<html><head><title>WSJ Headline</title></head><body><p>The lede only.</p>"
            + #"<script type="application/ld+json">{"@type":"NewsArticle","isAccessibleForFree":false}</script>"#
            + "</body></html>"
    }

    /// Runs the pipeline for `urlString` with prefetched `html` (so no real network)
    /// from the given `source`.
    private func process(
        _ urlString: String, html: String?, source: CaptureSource,
        timeout: TimeInterval = 10, fetcher: HTMLFetching = MockArticleFetcher()
    ) async -> Outcome {
        await IngestPipeline.process(
            IngestInput(url: url(urlString), source: source, prefetchedHTML: html),
            timeout: timeout, fetcher: fetcher)
    }

    // MARK: - Classification through the pipeline

    func testReadableArticleIsArticle() async {
        let outcome = await process("https://example.com/story", html: readableHTML(), source: .manual)
        guard case .article = outcome else { return XCTFail("expected .article, got \(outcome)") }
    }

    /// Safari's action extension supplies its already-loaded page HTML. That snapshot
    /// must take the direct text-extraction path and never wait for a second network
    /// request (or price lookup) before presenting the reader.
    func testActionExtensionPrefetchedArticleAvoidsNetworkFetch() async {
        let start = Date()
        let outcome = await IngestPipeline.process(
            IngestInput(
                url: url("https://example.com/story"), source: .appIntent,
                prefetchedHTML: readableHTML()),
            timeout: 1, fetcher: NeverReturningFetcher())

        guard case .article = outcome else {
            return XCTFail("expected the prefetched article, got \(outcome)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.9)
    }

    func testProductPageIsProduct() async {
        let productURL = "https://www.bunnings.com.au/ryobi-trimmer_p0208315"
        let html = BypassFixtures.html("Products/bunnings-nextdata.html")
        let outcome = await process(productURL, html: html, source: .manual)
        guard case let .product(product, _) = outcome else {
            return XCTFail("expected .product, got \(outcome)")
        }
        XCTAssertEqual(product.priceAmount, 99)
        XCTAssertEqual(product.priceCurrency, "AUD")
    }

    func testGoogleShoppingPageIsProductWithSellerListings() async {
        let html = BypassFixtures.html("Products/google-shopping-mova.html")
        let outcome = await process(
            "https://www.google.com/search?q=mova+v50+complete+vs+ultr&udm=28&shopmd=1",
            html: html,
            source: .manual)
        guard case let .product(product, _) = outcome else {
            return XCTFail("expected .product, got \(outcome)")
        }
        XCTAssertEqual(product.priceAmount, 1098)
        XCTAssertEqual(product.priceCurrency, "AUD")
        XCTAssertEqual(product.sellers.map(\.url.host), [
            "www.amazon.com.au",
            "www.harveynorman.com.au",
            "au.mova-tech.com",
        ])
    }

    func testHardPaywallLockedIsNeedsArchive() async {
        let outcome = await process("https://www.wsj.com/articles/x", html: lockedHTML(), source: .manual)
        guard case let .needsArchive(title) = outcome else {
            return XCTFail("expected .needsArchive, got \(outcome)")
        }
        XCTAssertEqual(title, "WSJ Headline")
    }

    func testOrdinaryUnreachablePageFails() async {
        // No prefetched HTML and the mock fetcher has no stub → genuine failure on an
        // ordinary host.
        let outcome = await IngestPipeline.process(
            IngestInput(url: url("https://ordinary.example/missing"), source: .manual),
            timeout: 10, fetcher: MockArticleFetcher())
        XCTAssertEqual(outcome, .failed)
    }

    // MARK: - Platform/video recognized BEFORE extraction (never an article)

    func testYouTubeIsVideoNeverArticle() async {
        // Even with article-looking HTML attached, a YouTube URL is classified by URL
        // first → `.video`, never text-extracted.
        let outcome = await process(
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ", html: readableHTML(), source: .manual)
        guard case let .video(platform, itemID) = outcome else {
            return XCTFail("expected .video, got \(outcome)")
        }
        XCTAssertEqual(platform, .youtube)
        XCTAssertEqual(itemID, "dQw4w9WgXcQ")
    }

    func testXPostIsSocialNeverArticle() async {
        let outcome = await process(
            "https://x.com/user/status/123", html: readableHTML(), source: .manual)
        guard case let .social(platform, itemID) = outcome else {
            return XCTFail("expected .social, got \(outcome)")
        }
        XCTAssertEqual(platform, .x)
        XCTAssertEqual(itemID, "123")
    }

    func testSpotifyTrackIsAudio() async {
        let outcome = await process(
            "https://open.spotify.com/track/abc", html: nil, source: .manual)
        guard case let .audio(platform, service, _) = outcome else {
            return XCTFail("expected .audio, got \(outcome)")
        }
        XCTAssertEqual(platform, .music)
        XCTAssertEqual(service, .spotify)
    }

    func testDocumentTypeWins() async {
        let outcome = await IngestPipeline.process(
            IngestInput(url: url("https://example.com/file.pdf"), source: .shareSheet,
                        documentType: "pdf"),
            timeout: 10, fetcher: MockArticleFetcher())
        XCTAssertEqual(outcome, .document(type: "pdf"))
    }

    // MARK: - PARITY: same input, every source → same Outcome

    func testParitySameInputAllSources() async {
        let cases: [(String, String?)] = [
            ("https://example.com/story", readableHTML()),
            ("https://www.wsj.com/articles/x", lockedHTML()),
            ("https://www.youtube.com/watch?v=dQw4w9WgXcQ", nil),
            ("https://x.com/user/status/123", nil),
        ]
        for (urlString, html) in cases {
            var outcomes: [Outcome] = []
            for source in CaptureSource.allCases {
                outcomes.append(await process(urlString, html: html, source: source))
            }
            let first = outcomes[0]
            for outcome in outcomes {
                XCTAssertEqual(outcome, first, "outcome must be identical across sources for \(urlString)")
            }
        }
    }

    func testResolvedResultCarriesTheSameOfflineUnwrappedURLForEverySource() async {
        let fbrpc = "fbrpc://nativethirdparty/f?app_id=123"
            + "&target_url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3DdQw4w9WgXcQ%26utm_source%3Dshare"
        let expected = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

        for source in CaptureSource.allCases {
            let result = await IngestPipeline.processResolved(
                IngestInput(url: url(fbrpc), source: source),
                timeout: 10, fetcher: MockArticleFetcher())
            XCTAssertEqual(result.url.absoluteString, expected)
            guard case .video(.youtube, itemID: "dQw4w9WgXcQ") = result.outcome else {
                return XCTFail("expected YouTube outcome for \(source)")
            }
        }
    }

    // MARK: - Overall timeout NEVER hangs

    /// A fetcher that never returns (sleeps far past the deadline). The pipeline's
    /// overall timeout must still resolve — to `.failed` on an ordinary host.
    private final class NeverReturningFetcher: HTMLFetching {
        func fetchHTML(from url: URL) async throws -> String {
            try await Task.sleep(nanoseconds: 60_000_000_000); return ""
        }
        func fetchHTML(from url: URL, userAgent: String, xForwardedFor: String?) async throws -> String {
            try await Task.sleep(nanoseconds: 60_000_000_000); return ""
        }
        func fetchHTML(from url: URL, referer: String) async throws -> String {
            try await Task.sleep(nanoseconds: 60_000_000_000); return ""
        }
        func fetchHTMLWithoutCookies(from url: URL) async throws -> String {
            try await Task.sleep(nanoseconds: 60_000_000_000); return ""
        }
        func fetchWaybackRawHTML(for url: URL) async throws -> String {
            try await Task.sleep(nanoseconds: 60_000_000_000); return ""
        }
        func fetchJinaReader(for url: URL) async throws -> String {
            try await Task.sleep(nanoseconds: 60_000_000_000); return ""
        }
    }

    func testOverallTimeoutResolvesToFailed() async {
        let start = Date()
        let outcome = await IngestPipeline.process(
            IngestInput(url: url("https://slow.example/article"), source: .manual),
            timeout: 0.5, fetcher: NeverReturningFetcher())
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(outcome, .failed)
        XCTAssertLessThan(elapsed, 5, "the overall timeout must resolve promptly, not hang")
    }

    func testOverallTimeoutOnHardPaywallParksForArchive() async {
        let outcome = await IngestPipeline.process(
            IngestInput(url: url("https://www.wsj.com/articles/slow"), source: .manual),
            timeout: 0.5, fetcher: NeverReturningFetcher())
        guard case .needsArchive = outcome else {
            return XCTFail("a hard-paywall host that times out must park for the archive reader, got \(outcome)")
        }
    }
}

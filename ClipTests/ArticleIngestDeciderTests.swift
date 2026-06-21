//
//  ArticleIngestDeciderTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

/// Exercises the SINGLE shared `ArticleIngestDecider.decide` routine that the main
/// app (`ReadingListIngestor.ingest`) and both share-sheet extensions now call. The
/// key assertions are PARITY: the same URL/HTML yields the same classification
/// regardless of entry point, because there's only one routine. Driven by a mock
/// `HTMLFetching`; the product price comes from the real `ProductMetadataExtractor`
/// over fixture HTML with `render: nil` (the extension-safe path — no WebView), so the
/// whole test is network-free.
final class ArticleIngestDeciderTests: XCTestCase {

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else { fatalError("bad test URL: \(string)") }
        return url
    }

    /// A long readable article body.
    private func readableHTML() -> String {
        let paragraph = "<p>" + String(repeating: "An ordinary readable sentence about the topic. ", count: 30) + "</p>"
        return "<html><head><title>Real Story</title></head><body><article>\(paragraph)\(paragraph)</article></body></html>"
    }

    /// A locked publisher page: a short teaser + the schema.org locked declaration.
    private func lockedHTML() -> String {
        "<html><head><title>WSJ Headline</title></head><body><p>The lede only.</p>"
            + #"<script type="application/ld+json">{"@type":"NewsArticle","isAccessibleForFree":false}</script>"#
            + "</body></html>"
    }

    private func decide(
        _ urlString: String, html: String?, fetcher: MockArticleFetcher
    ) async -> ArticleIngestDecision {
        // render: nil ⇒ static-only price extraction (the extension-safe path).
        await ArticleIngestDecider.decide(
            url: url(urlString), prefetchedHTML: html, fetcher: fetcher)
    }

    // MARK: classification cases

    func testReadableArticleIsArticle() async {
        let fetcher = MockArticleFetcher()
        let decision = await decide("https://example.com/story", html: readableHTML(), fetcher: fetcher)
        guard case .article = decision else { return XCTFail("expected .article, got \(decision)") }
    }

    func testProductPageIsPriceTracker() async {
        let productURL = "https://www.bunnings.com.au/ryobi-18v-one-25-30cm-cordless-line-trimmer-tool-only_p0208315"
        let html = BypassFixtures.html("Products/bunnings-nextdata.html")
        let fetcher = MockArticleFetcher()
        // Bunnings has no per-host rule → the generic embedded-JSON fallback recovers
        // the price (99 AUD) from __NEXT_DATA__ statically, no WebView needed.
        let decision = await decide(productURL, html: html, fetcher: fetcher)
        guard case let .priceTracker(product, _) = decision else {
            return XCTFail("expected .priceTracker, got \(decision)")
        }
        XCTAssertEqual(product.priceAmount, 99)
        XCTAssertEqual(product.priceCurrency, "AUD")
    }

    /// A product candidate whose price can't be fetched falls through to the article
    /// path (never a broken tracker) — here the page is also a readable article shell.
    func testProductWithoutPriceFallsThroughToArticle() async {
        let productURL = "https://shop.example.com/products/widget"
        // Product signals (og:type product + /products/ path) but no structured price,
        // plus a long readable body so the article path succeeds.
        let html = "<html><head><meta property=\"og:type\" content=\"product\">"
            + "<title>Widget</title></head><body><article>"
            + readableHTML() + "</article></body></html>"
        let fetcher = MockArticleFetcher()
        // MockPriceFetcher returns nil (no canned price) → no tracker.
        let decision = await decide(productURL, html: html, fetcher: fetcher)
        guard case .article = decision else { return XCTFail("expected .article, got \(decision)") }
    }

    func testHardPaywallLockedIsNeedsArchive() async {
        let fetcher = MockArticleFetcher()
        // The silent bypass strategies all fail (no canned HTML for them) → needsArchive.
        let decision = await decide("https://www.wsj.com/articles/x", html: lockedHTML(), fetcher: fetcher)
        guard case let .needsArchive(title) = decision else {
            return XCTFail("expected .needsArchive, got \(decision)")
        }
        XCTAssertEqual(title, "WSJ Headline")
    }

    func testOrdinaryUnreachablePageFails() async {
        let fetcher = MockArticleFetcher()
        // No HTML at all (fetch failed) on an ordinary host, no silent strategy works.
        let decision = await ArticleIngestDecider.decide(
            url: url("https://ordinary.example/missing"), prefetchedHTML: nil, fetcher: fetcher)
        XCTAssertEqual(decision, .failed)
    }

    func testSkipProductDetectionForcesArticlePath() async {
        // A product page (with a recoverable embedded price), but skipProductDetection
        // is set → it MUST take the article path and never become a price tracker.
        let productURL = "https://www.bunnings.com.au/ryobi-18v-one-25-30cm_p0208315"
        let html = "<html><head><meta property=\"og:type\" content=\"product\">"
            + "<script id=\"__NEXT_DATA__\" type=\"application/json\">"
            + "{\"a\":{\"currencyIso\":\"AUD\",\"priceAvailable\":true,\"value\":50}}</script></head>"
            + "<body><article>\(readableHTML())</article></body></html>"
        let fetcher = MockArticleFetcher()
        let decision = await ArticleIngestDecider.decide(
            url: url(productURL), prefetchedHTML: html, skipProductDetection: true,
            fetcher: fetcher)
        guard case .article = decision else { return XCTFail("expected .article, got \(decision)") }
    }

    // MARK: PARITY — the same inputs yield the same decision through every entry point

    /// Both the main-app ingestor and the extensions call `decide`, so identical
    /// inputs MUST produce identical decisions. We assert this directly: the routine
    /// is deterministic given (url, html, fetcher, price).
    func testParitySameInputsSameDecision() async {
        let cases: [(String, String)] = [
            ("https://example.com/story", readableHTML()),
            ("https://www.wsj.com/articles/x", lockedHTML()),
        ]
        for (urlString, html) in cases {
            let a = await decide(urlString, html: html, fetcher: MockArticleFetcher())
            let b = await decide(urlString, html: html, fetcher: MockArticleFetcher())
            XCTAssertEqual(a, b, "decision must be identical for \(urlString)")
        }
    }

    /// A hard-paywall host the MAIN APP would route to the archive must NOT be dropped
    /// by the extension — they call the same routine, so the decision is the same
    /// `.needsArchive` either way (the divergence the old action extension had, where
    /// it called ArticleResolver.resolve directly and skipped product detection, is
    /// gone because there's now one routine).
    func testHardPaywallNotDroppedByEitherEntryPoint() async {
        let decision = await decide("https://www.ft.com/content/x", html: lockedHTML(), fetcher: MockArticleFetcher())
        if case .needsArchive = decision { return }
        XCTFail("a hard-paywall host must route to .needsArchive, got \(decision)")
    }

    /// A false-positive page (a readable article on a host that merely looks paywall-y)
    /// is saved as a normal article by BOTH entry points.
    func testFalsePositiveSavedAsArticleByBoth() async {
        // Long readable body, no lock declaration, no gate marker.
        let decision = await decide("https://blog.example.com/post", html: readableHTML(), fetcher: MockArticleFetcher())
        guard case .article = decision else { return XCTFail("expected .article, got \(decision)") }
    }
}

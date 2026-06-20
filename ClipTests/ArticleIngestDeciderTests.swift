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
/// `HTMLFetching` + `PriceFetching` so it's network-free.
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
        _ urlString: String, html: String?, fetcher: MockArticleFetcher,
        price: MockPriceFetcher = MockPriceFetcher()
    ) async -> ArticleIngestDecision {
        await ArticleIngestDecider.decide(
            url: url(urlString), prefetchedHTML: html, fetcher: fetcher, priceFetcher: price)
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
        let price = MockPriceFetcher()
        price.priceByURL[productURL] = ProductPrice(amount: 99, currency: "AUD")
        let fetcher = MockArticleFetcher()
        let decision = await decide(productURL, html: html, fetcher: fetcher, price: price)
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
        // A product page, but forceArticle/skipProductDetection is set → article path.
        let productURL = "https://www.bunnings.com.au/widget_p0208315"
        let html = "<html><head><meta property=\"og:type\" content=\"product\"></head>"
            + "<body><article>\(readableHTML())</article></body></html>"
        let price = MockPriceFetcher()
        price.priceByURL[productURL] = ProductPrice(amount: 50, currency: "AUD")
        let fetcher = MockArticleFetcher()
        let decision = await ArticleIngestDecider.decide(
            url: url(productURL), prefetchedHTML: html, skipProductDetection: true,
            fetcher: fetcher, priceFetcher: price)
        guard case .article = decision else { return XCTFail("expected .article, got \(decision)") }
        XCTAssertTrue(price.requestedURLs.isEmpty, "price must not be fetched when product detection is skipped")
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

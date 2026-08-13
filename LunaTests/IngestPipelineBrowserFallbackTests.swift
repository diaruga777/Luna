//
//  IngestPipelineBrowserFallbackTests.swift
//  LunaTests
//

import LunaArticleIngest
import LunaPriceIngest
import LunaIngest
import LunaHTMLClassification
import LunaModels
import LunaPaywallBypass
import XCTest
@testable import Luna

/// A snapshot fallback that answers `product` for exactly one page.
private struct StubProductInfoFallback: ProductInfoFallbackProviding {
    let url: URL
    let product: ProductInfo

    func productInfo(forPageURL url: URL) -> ProductInfo? {
        url == self.url ? product : nil
    }
}

final class IngestPipelineBrowserFallbackTests: XCTestCase {

    /// Amazon often refuses the app/extension URLSession even though Safari's
    /// rendered page already produced a passive snapshot. A known product host
    /// must still offer the product processor its fallback when the fetch has
    /// no HTML at all.
    func testKnownAmazonURLUsesSnapshotFallbackWhenNativeFetchIsBlocked() async {
        let url = URL(string: "https://www.amazon.com.au/acme/dp/B0ACME1234")!
        let expected = ProductInfo(
            name: "Acme Toaster", priceAmount: 42, priceCurrency: "AUD",
            imageURL: URL(string: "https://m.media-amazon.com/images/I/acme.jpg"),
            brand: "Acme", productID: "B0ACME1234",
            identifiers: ProductIdentifiers(sku: "B0ACME1234", brand: "Acme"))
        let processor = ProductIngestProcessor(
            fallback: StubProductInfoFallback(url: url, product: expected))

        let outcome = await IngestPipeline.process(
            IngestInput(url: url, source: .manual), timeout: 1,
            fetcher: MockArticleFetcher(), productProcessor: processor)

        guard case let .product(product, html) = outcome else {
            return XCTFail("Expected snapshot-backed Amazon product, got \(outcome)")
        }
        XCTAssertEqual(product, expected)
        XCTAssertTrue(html.isEmpty)
    }

    /// A generic SPA state shape with `value` beside a nested ISO-currency object
    /// must complete the product route. Recognition without mandatory-price
    /// extraction used to fall through to Reader even though Safari showed Track.
    func testNestedCurrencyProductStateRoutesToPriceTracker() async throws {
        let url = URL(string:
            "https://shop.example/au/en/products/P123456-000/00?color=31&size=003"
        )!
        let html = BypassFixtures.html("Products/nested-currency-state.html")

        let outcome = await IngestPipeline.process(
            IngestInput(url: url, source: .paste, prefetchedHTML: html),
            timeout: 1,
            fetcher: MockArticleFetcher(),
            articleProcessor: ArticleIngestProcessor(),
            productProcessor: ProductIngestProcessor()
        )

        guard case let .product(product, _) = outcome else {
            return XCTFail("Expected a priced product, got \(outcome)")
        }
        XCTAssertEqual(product.name, "Pleated Travel Skort")
        XCTAssertEqual(product.priceAmount, Decimal(string: "49.9"))
        XCTAssertEqual(product.priceCurrency, "AUD")
    }

    /// Publisher pages can bundle priced store cards, subscription offers, and the
    /// same generic commerce components used elsewhere on the site. Those secondary
    /// components must not override an authoritative hard-paywall news-host match.
    /// This reproduces the New Yorker failure with deliberately strong product
    /// signals that would classify an otherwise-unknown page as a product.
    func testKnownPaywallPublisherCommerceMarkupStillRoutesToUnlock() async {
        let url = URL(string:
            "https://www.newyorker.com/culture/the-weekend-essay/the-voice-of-google"
        )!
        let html = """
        <html><head>
          <title>The Voice of Google | The New Yorker</title>
          <meta property="og:type" content="article">
          <meta property="product:price:amount" content="120.00">
          <meta property="product:price:currency" content="USD">
        </head><body>
          <article><h1>The Voice of Google</h1><p>Subscriber preview.</p></article>
          <button>Add to cart</button><div>Star Rating: 5 out of 5</div>
        </body></html>
        """

        XCTAssertNotNil(
            ProductPageDetector().detect(urlString: url.absoluteString, html: html),
            "The fixture must retain the commerce false-positive that exercises precedence"
        )
        XCTAssertEqual(Classifier.classify(url: url), .paywalledArticle(hardHost: true))

        let outcome = await IngestPipeline.process(
            IngestInput(url: url, source: .paste, prefetchedHTML: html),
            timeout: 1,
            fetcher: MockArticleFetcher(),
            articleProcessor: ArticleIngestProcessor(),
            productProcessor: ProductIngestProcessor()
        )

        XCTAssertEqual(outcome, .needsArchive(title: "The Voice of Google | The New Yorker"))
        XCTAssertEqual(
            BypassPlan.make(for: url, directHTML: html).webPreStages,
            [.directUnlock],
            "Correct categorization must retain New Yorker's configured unlock route"
        )
    }

    /// Reuters currently puts URLSession behind a DataDome 401 while the same page
    /// remains readable in a browser with Luna's site rule active. A title-less
    /// background failure must therefore park for the direct-unlock WKWebView leg,
    /// not become a terminal failed item before that browser leg can run.
    func testReutersBackgroundRejectionRoutesToBrowserRecovery() async {
        let url = URL(string:
            "https://www.reuters.com/world/meta-used-ai-target-workers-with-medical-conditions-layoffs-former-employees-2026-07-14/"
        )!
        let fetcher = MockArticleFetcher() // no stub: every URLSession attempt fails

        let outcome = await IngestPipeline.process(
            IngestInput(url: url, source: .paste),
            timeout: 1,
            fetcher: fetcher
        )

        XCTAssertEqual(
            outcome,
            .needsArchive(title:
                "Meta Used Ai Target Workers With Medical Conditions Layoffs Former Employees")
        )
        XCTAssertEqual(
            BypassPlan.make(for: url, directHTML: nil).webPreStages,
            [.directUnlock],
            "Reuters must still have the direct-unlock browser stage that this outcome opens"
        )
    }

    /// A FREE article on a ruleless host behind Vercel's bot mitigation: every silent
    /// strategy gets HTTP 429 and a "Vercel Security Checkpoint" body, so nothing is
    /// learned about the page — only that URLSession was not welcome. A real WKWebView
    /// loads the same URL with a 200 and all 57 paragraphs, so this must park for the
    /// browser leg rather than becoming a terminal failed item. This is the reported
    /// piratewires.com defect: the host has no unlock rule (it is on the upstream
    /// `noFix` list), which used to be the only way to reach `.directUnlock`.
    func testBotMitigatedRulelessHostParksForBrowserRecovery() async {
        let url = URL(string:
            "https://www.piratewires.com/p/inside-the-coke-fueled-rise-and-fall")!
        let fetcher = MockArticleFetcher()
        fetcher.fetchErrorsByURL[url.absoluteString] = .badResponse(status: 429)

        let outcome = await IngestPipeline.process(
            IngestInput(url: url, source: .paste),
            timeout: 1,
            fetcher: fetcher,
            articleProcessor: ArticleIngestProcessor(),
            productProcessor: ProductIngestProcessor()
        )

        XCTAssertEqual(
            outcome,
            .needsArchive(title: "Inside The Coke Fueled Rise And Fall"))
        XCTAssertEqual(
            BypassPlan.make(for: url, directHTML: nil,
                            directFailure: .httpStatus(429)).webPreStages,
            [.directUnlock],
            "the 429 refusal is what opens the browser leg for a host with no rule")
    }

    /// Keep the other side of the routing boundary explicit: an ordinary host with
    /// no rule and no readable response remains a real failure rather than sending
    /// every broken URL through the interactive archive UI.
    func testUnknownHostWithoutBrowserRuleStillFails() async {
        let url = URL(string: "https://example.com/unreachable-article")!

        let outcome = await IngestPipeline.process(
            IngestInput(url: url, source: .paste),
            timeout: 1,
            fetcher: MockArticleFetcher(),
            articleProcessor: ArticleIngestProcessor(),
            productProcessor: ProductIngestProcessor()
        )

        // Match the case, not its reason: which reason the mock's refusal maps to
        // is that mock's business, and pinning it here would make an unrelated
        // fetcher change look like a routing regression.
        guard case .failed = outcome else {
            return XCTFail("expected a genuine failure, got \(outcome)")
        }
    }
}

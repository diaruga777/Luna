//
//  IngestPipelineBrowserFallbackTests.swift
//  LunaTests
//

import LunaIngest
import LunaHTMLClassification
import LunaPaywallBypass
import XCTest
@testable import Luna

final class IngestPipelineBrowserFallbackTests: XCTestCase {

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
            fetcher: MockArticleFetcher()
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
            fetcher: MockArticleFetcher()
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

    /// Keep the other side of the routing boundary explicit: an ordinary host with
    /// no rule and no readable response remains a real failure rather than sending
    /// every broken URL through the interactive archive UI.
    func testUnknownHostWithoutBrowserRuleStillFails() async {
        let url = URL(string: "https://example.com/unreachable-article")!

        let outcome = await IngestPipeline.process(
            IngestInput(url: url, source: .paste),
            timeout: 1,
            fetcher: MockArticleFetcher()
        )

        XCTAssertEqual(outcome, .failed)
    }
}

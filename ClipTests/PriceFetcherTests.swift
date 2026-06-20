//
//  PriceFetcherTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

/// Coverage for `PriceFetcher`'s resolution strategy: static markup (structured
/// data → embedded JSON) first, then the WKWebView render fallback for prices that
/// only exist after client-side rendering, and the no-price result that lets a
/// detected product fall back to a plain article.
final class PriceFetcherTests: XCTestCase {

    /// A product page whose price is rendered by JS: no JSON-LD / OG / microdata /
    /// embedded price in the static markup. The static path must return nil.
    private let jsRenderedHTML = """
    <html><head><meta property="og:type" content="product">
    <title>Cordless Drill</title></head>
    <body><button>Add to cart</button><div>4.5 out of 5</div>
    <div id="price">loading…</div></body></html>
    """

    /// The same page AFTER JS ran: the rendered DOM now carries an embedded
    /// app-state price blob (what `WebViewPriceRenderer` would scrape).
    private let renderedWithPriceHTML = """
    <html><head><meta property="og:type" content="product"><title>Cordless Drill</title>
    <script type="application/json">{"product":{"sellPrice":"149.00","priceCurrency":"USD"}}</script>
    </head><body><button>Add to cart</button></body></html>
    """

    // MARK: - Static path wins (no WebView)

    func testStaticEmbeddedPriceUsesPrefetchedHTMLNoRender() async {
        var rendered = false
        let fetcher = PriceFetcher(
            fetcher: MockArticleFetcher(),
            renderHTML: { _ in rendered = true; return nil })
        let url = "https://www.bunnings.com.au/x_p0208315"
        let html = BypassFixtures.html("Products/bunnings-nextdata.html")

        let price = await fetcher.fetchPrice(forURLString: url, prefetchedHTML: html)
        XCTAssertEqual(price?.amount, Decimal(99))
        XCTAssertEqual(price?.currency, "AUD")
        XCTAssertFalse(rendered, "A statically-present price must never trigger the WebView fallback.")
    }

    func testStructuredPriceFetchedWhenNoPrefetchedHTML() async {
        let url = "https://shop.example/dp/B09"
        let mock = MockArticleFetcher()
        mock.htmlByURL[url] = """
        <html><head><script type="application/ld+json">
        {"@type":"Product","name":"Thing","offers":{"price":"12.50","priceCurrency":"GBP"}}
        </script></head><body></body></html>
        """
        let fetcher = PriceFetcher(fetcher: mock, renderHTML: { _ in nil })

        let price = await fetcher.fetchPrice(forURLString: url, prefetchedHTML: nil)
        XCTAssertEqual(price?.amount, Decimal(string: "12.50"))
        XCTAssertEqual(price?.currency, "GBP")
    }

    // MARK: - WebView fallback

    func testRenderFallbackRecoversJSLoadedPrice() async {
        let url = "https://shop.example/p/12345"
        let mock = MockArticleFetcher()
        mock.htmlByURL[url] = jsRenderedHTML   // static markup has no price
        let captured = renderedWithPriceHTML
        let fetcher = PriceFetcher(fetcher: mock, renderHTML: { _ in captured })

        let price = await fetcher.fetchPrice(forURLString: url, prefetchedHTML: jsRenderedHTML)
        XCTAssertEqual(price?.amount, Decimal(string: "149.00"))
        XCTAssertEqual(price?.currency, "USD")
    }

    // MARK: - No price anywhere → article fallback

    func testNoPriceWhenStaticAndRenderBothEmpty() async {
        let url = "https://shop.example/p/12345"
        let mock = MockArticleFetcher()
        mock.htmlByURL[url] = jsRenderedHTML
        // The render also fails to surface a price (still loading / blocked).
        let fetcher = PriceFetcher(fetcher: mock, renderHTML: { _ in self.jsRenderedHTML })

        let price = await fetcher.fetchPrice(forURLString: url, prefetchedHTML: jsRenderedHTML)
        XCTAssertNil(price, "No price by any method → nil, so the caller saves a plain article.")
    }
}

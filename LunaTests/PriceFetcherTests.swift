//
//  PriceFetcherTests.swift
//  LunaTests
//

import LunaPriceUI
import XCTest
@testable import Luna

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

    /// The render tier, stubbed: it answers `html`, counts how often it was
    /// asked, and can be made to hang so the overall timeout has something to
    /// fire against.
    private final class StubRenderer: PriceHTMLRendering, @unchecked Sendable {
        private let html: String?
        private let sleepNanoseconds: UInt64?
        private(set) var renderCount = 0

        init(html: String?, sleepNanoseconds: UInt64? = nil) {
            self.html = html
            self.sleepNanoseconds = sleepNanoseconds
        }

        func renderedHTML(for url: URL) async -> String? {
            renderCount += 1
            if let sleepNanoseconds { try? await Task.sleep(nanoseconds: sleepNanoseconds) }
            return html
        }
    }

    // MARK: - Static path wins (no WebView)

    func testStaticEmbeddedPriceUsesPrefetchedHTMLNoRender() async {
        let renderer = StubRenderer(html: nil)
        let fetcher = PriceFetcher(fetcher: MockArticleFetcher(), renderer: renderer)
        let url = "https://www.bunnings.com.au/x_p0208315"
        let html = BypassFixtures.html("Products/bunnings-nextdata.html")

        let price = await fetcher.fetchPrice(forURLString: url, prefetchedHTML: html)
        XCTAssertEqual(price?.amount, Decimal(99))
        XCTAssertEqual(price?.currency, "AUD")
        XCTAssertEqual(
            renderer.renderCount, 0,
            "A statically-present price must never trigger the WebView fallback.")
    }

    func testStructuredPriceFetchedWhenNoPrefetchedHTML() async {
        let url = "https://shop.example/dp/B09"
        let mock = MockArticleFetcher()
        mock.htmlByURL[url] = """
        <html><head><script type="application/ld+json">
        {"@type":"Product","name":"Thing","offers":{"price":"12.50","priceCurrency":"GBP"}}
        </script></head><body></body></html>
        """
        let fetcher = PriceFetcher(fetcher: mock, renderer: StubRenderer(html: nil))

        let price = await fetcher.fetchPrice(forURLString: url, prefetchedHTML: nil)
        XCTAssertEqual(price?.amount, Decimal(string: "12.50"))
        XCTAssertEqual(price?.currency, "GBP")
    }

    // MARK: - WebView fallback

    func testRenderFallbackRecoversJSLoadedPrice() async {
        let url = "https://shop.example/p/12345"
        let mock = MockArticleFetcher()
        mock.htmlByURL[url] = jsRenderedHTML   // static markup has no price
        let fetcher = PriceFetcher(
            fetcher: mock, renderer: StubRenderer(html: renderedWithPriceHTML))

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
        let fetcher = PriceFetcher(
            fetcher: mock, renderer: StubRenderer(html: jsRenderedHTML))

        let price = await fetcher.fetchPrice(forURLString: url, prefetchedHTML: jsRenderedHTML)
        XCTAssertNil(price, "No price by any method → nil, so the caller saves a plain article.")
    }

    // MARK: - Hard overall timeout (no infinite spin)

    /// A render that never returns must NOT hang the fetch: the overall timeout
    /// fires, `fetchPrice` returns nil, and the caller falls back to a plain article.
    func testOverallTimeoutTerminatesAHangingRender() async {
        let url = "https://shop.example/p/12345"
        let mock = MockArticleFetcher()
        mock.htmlByURL[url] = jsRenderedHTML   // static path finds no price
        let fetcher = PriceFetcher(
            fetcher: mock,
            // Never completes on its own — only the overall timeout can end this.
            renderer: StubRenderer(
                html: renderedWithPriceHTML, sleepNanoseconds: 60_000_000_000),
            overallTimeoutSeconds: 1)

        let start = Date()
        let price = await fetcher.fetchPrice(forURLString: url, prefetchedHTML: jsRenderedHTML)
        XCTAssertNil(price, "A hanging render must time out to nil, never spin forever.")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5,
                          "The fetch must end at the hard timeout, not wait for the render.")
    }

    // MARK: - Amazon static path (no WebView)

    /// The Amazon /dp/ page resolves its price via the FAST static path — the
    /// WebView render is never reached (the spin-forever bug was the render path).
    func testAmazonStaticPriceUsesNoRender() async {
        let renderer = StubRenderer(html: nil)
        let fetcher = PriceFetcher(fetcher: MockArticleFetcher(), renderer: renderer)
        let url = "https://www.amazon.com.au/Mrisata-Rotating-Electric-Machine-Conveyor/dp/B0CWRSYTTK"
        let html = BypassFixtures.html("Products/amazon-dp.html")

        let price = await fetcher.fetchPrice(forURLString: url, prefetchedHTML: html)
        XCTAssertEqual(price?.amount, Decimal(string: "39.99"))
        XCTAssertEqual(price?.currency, "AUD")
        XCTAssertEqual(
            renderer.renderCount, 0,
            "Amazon's static price must resolve without the WebView fallback.")
    }
}

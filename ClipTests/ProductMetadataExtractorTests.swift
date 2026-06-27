//
//  ProductMetadataExtractorTests.swift
//  ClipTests
//

import ClipHTMLClassification
import XCTest
@testable import Clip

/// Exercises `ProductMetadataExtractor` + the per-host `ProductPriceRule` table: one
/// parse, one price source, a mandatory price, per-rule currency (no silent USD), and
/// the render tier being structurally unreachable when `render: nil`.
final class ProductMetadataExtractorTests: XCTestCase {

    private let extractor = ProductMetadataExtractor()

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else { fatalError("bad test URL: \(string)") }
        return url
    }

    /// Static extraction with NO render tier (the extension-safe path).
    private func extract(_ urlString: String, fixture: String) async -> ProductMetadata? {
        await extractor.extract(url: url(urlString), html: BypassFixtures.html("Products/\(fixture)"))
    }

    // MARK: - Amazon

    func testAmazonBuyBoxPriceFromPriceModelWithTLDCurrency() async {
        // amazon-dp.html declares "priceAmount":39.99 / "displayPrice":"$39.99", no
        // currency code → AUD from the amazon.com.au TLD.
        let meta = await extract(
            "https://www.amazon.com.au/Mrisata/dp/B0CWRSYTTK", fixture: "amazon-dp.html")
        XCTAssertEqual(meta?.price.amount, Decimal(string: "39.99"))
        XCTAssertEqual(meta?.price.currency, "AUD")
    }

    func testAmazonBuyBoxWinsOverStrikethroughListPrice() async {
        // amazon-listprice.html has a strikethrough list price ($59.99) BEFORE the
        // buy-box price ($42.50). The buy-box-scoped .a-offscreen must win.
        let meta = await extract(
            "https://www.amazon.com/Acme-Widget/dp/B0ACME1234", fixture: "amazon-listprice.html")
        XCTAssertEqual(meta?.price.amount, Decimal(string: "42.50"))
        XCTAssertEqual(meta?.price.currency, "USD")
    }

    func testAmazonLookalikeHostDoesNotMatchAmazonRule() {
        // amazon.scam.com is NOT an Amazon storefront — the rule must decline it.
        XCTAssertFalse(AmazonPriceRule().matches(host: "amazon.scam.com"))
        XCTAssertFalse(AmazonPriceRule().matches(host: "cdn.amazon.akamai.net"))
        XCTAssertTrue(AmazonPriceRule().matches(host: "amazon.com"))
        XCTAssertTrue(AmazonPriceRule().matches(host: "www.amazon.com.au"))
        XCTAssertTrue(AmazonPriceRule().matches(host: "amazon.co.uk"))
    }

    func testAmazonStorefrontRegistryIncludesInternationalMarkets() {
        let rule = AmazonPriceRule()
        let expectedCurrencies = [
            "amazon.com.mx": "MXN", "amazon.com.br": "BRL", "amazon.pl": "PLN",
            "amazon.com.tr": "TRY", "amazon.com.be": "EUR", "amazon.ie": "EUR",
            "amazon.ae": "AED", "amazon.sa": "SAR", "amazon.eg": "EGP",
            "amazon.co.za": "ZAR", "amazon.sg": "SGD", "amazon.se": "SEK",
        ]
        for (host, currency) in expectedCurrencies {
            XCTAssertTrue(rule.matches(host: "www.\(host)"), "expected storefront \(host)")
            XCTAssertEqual(ProductPageDetector.amazonCurrency(forHost: host), currency)
        }
    }

    // MARK: - Target / Walmart (__NEXT_DATA__)

    func testTargetNextDataCurrentRetail() async {
        let meta = await extract("https://www.target.com/p/mug/-/A-54321", fixture: "target-nextdata.html")
        XCTAssertEqual(meta?.price.amount, Decimal(string: "24.99"))
        XCTAssertEqual(meta?.price.currency, "USD")
        XCTAssertEqual(meta?.name, "Threshold 12oz Stoneware Mug")
    }

    func testWalmartNextDataCurrentPrice() async {
        let meta = await extract("https://www.walmart.com/ip/cooker/123456789", fixture: "walmart-nextdata.html")
        XCTAssertEqual(meta?.price.amount, Decimal(string: "17.88"))
        XCTAssertEqual(meta?.price.currency, "USD")
        XCTAssertEqual(meta?.name, "Mainstays 5-Quart Slow Cooker")
    }

    // MARK: - Generic fallback (no host rule)

    func testGenericJSONLDProduct() async {
        // generic-jsonld-graph.html: a JSON-LD Product/Offer (EU comma price).
        let meta = await extract("https://shop.example.de/p/widget", fixture: "generic-jsonld-graph.html")
        XCTAssertNotNil(meta?.price)
        XCTAssertNotNil(meta?.price.currency)
    }

    func testGenericShopifyOGProduct() async {
        let meta = await extract("https://store.example.com/products/thing", fixture: "shopify-og.html")
        XCTAssertNotNil(meta?.price)
    }

    func testGenericBunningsEmbeddedJSON() async {
        // Bunnings is not in the host-rule table → the generic embedded-JSON fallback
        // recovers 99 AUD from __NEXT_DATA__.
        let meta = await extract(
            "https://www.bunnings.com.au/widget_p0208315", fixture: "bunnings-nextdata.html")
        XCTAssertEqual(meta?.price.amount, 99)
        XCTAssertEqual(meta?.price.currency, "AUD")
    }

    // MARK: - No price ⇒ no metadata (mandatory-price invariant)

    func testNoPriceYieldsNil() async {
        let meta = await extract("https://news.example.com/story", fixture: "article-no-price.html")
        XCTAssertNil(meta, "a page with no resolvable price must not produce metadata")
    }

    // MARK: - Render tier is unreachable with render: nil (the extension fix)

    func testRenderTierUnreachableWhenRenderIsNil() async {
        // A page whose price ONLY exists after a JS render: static extraction finds
        // nothing, and with render: nil there is no WebView, so it resolves to nil.
        let jsOnly = "<html><head><meta property=\"og:type\" content=\"product\">"
            + "<title>JS Widget</title></head><body><div id=\"price\"></div>"
            + "<script>document.getElementById('price').textContent='$10.00'</script></body></html>"
        let nilRender = await extractor.extract(url: url("https://shop.example.com/p/js"), html: jsOnly)
        XCTAssertNil(nilRender, "no render tier in extensions ⇒ JS-only price → nil → article")
    }

    func testRenderTierUsedWhenRenderProvided() async {
        // The main-app path: static finds nothing, the injected render returns priced
        // markup, and the SAME static extractor pulls the price from the rendered HTML.
        let jsOnly = "<html><head><title>JS Widget</title></head><body></body></html>"
        let rendered = "<html><head><meta property=\"product:price:amount\" content=\"10.00\">"
            + "<meta property=\"product:price:currency\" content=\"USD\"><title>JS Widget</title></head>"
            + "<body></body></html>"
        let meta = await extractor.extract(
            url: url("https://shop.example.com/p/js"), html: jsOnly,
            render: { _ in rendered })
        XCTAssertEqual(meta?.price.amount, Decimal(string: "10.00"))
        XCTAssertEqual(meta?.price.currency, "USD")
    }

    // MARK: - Determinism

    func testExtractionIsDeterministicAcrossRuns() async {
        let first = await extract("https://www.target.com/p/mug/-/A-54321", fixture: "target-nextdata.html")
        let second = await extract("https://www.target.com/p/mug/-/A-54321", fixture: "target-nextdata.html")
        XCTAssertEqual(first, second)
    }
}

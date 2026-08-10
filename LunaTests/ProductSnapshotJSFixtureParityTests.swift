//
//  ProductSnapshotJSFixtureParityTests.swift
//  LunaTests
//

import XCTest

/// `content.js`'s `extractProductSnapshot()` against a small fixture matrix —
/// JSON-LD, OpenGraph, microdata, an Amazon-shaped URL for the retailer item
/// id, and a no-structured-price page (must yield null, mirroring "the price
/// is mandatory"). Modeled on `ProductPageJSFixtureParityTests`.
@MainActor
final class ProductSnapshotJSFixtureParityTests: XCTestCase {

    private lazy var js = SafariJSTestHarness(self)

    private func extract(html: String, urlString: String) -> [String: Any]? {
        js.load(html: html, urlString: urlString, scripts: [
            SafariJSTestHarness.newsHosts,
            SafariJSTestHarness.productRules,
            SafariJSTestHarness.contentScript,
        ])
        let json = js.string("JSON.stringify(window.__lunaExtractProductSnapshot())")
        guard let json, json != "null",
              let data = json.data(using: .utf8)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func testJSONLDProductOfferExtractsPriceCurrencyAndIdentifiers() {
        let html = """
        <script type="application/ld+json">
        {"@type":"Product","name":"Acme Widget","brand":{"name":"Acme"},
         "gtin13":"0012345678905","mpn":"MPN-1",
         "offers":{"price":"19.99","priceCurrency":"USD"}}
        </script>
        """
        let snapshot = extract(html: html, urlString: "https://shop.example/products/widget")
        XCTAssertEqual(snapshot?["name"] as? String, "Acme Widget")
        XCTAssertEqual(snapshot?["price"] as? String, "19.99")
        XCTAssertEqual(snapshot?["currency"] as? String, "USD")
        XCTAssertEqual(snapshot?["gtin"] as? String, "0012345678905")
        XCTAssertEqual(snapshot?["mpn"] as? String, "MPN-1")
        XCTAssertEqual(snapshot?["brand"] as? String, "Acme")
        XCTAssertEqual(snapshot?["url"] as? String, "https://shop.example/products/widget")
    }

    func testOpenGraphPriceMetaExtracts() {
        let html = """
        <meta property="og:title" content="Acme Widget">
        <meta property="product:price:amount" content="24.50">
        <meta property="product:price:currency" content="GBP">
        <meta property="product:brand" content="Acme">
        """
        let snapshot = extract(html: html, urlString: "https://shop.example/products/widget-2")
        XCTAssertEqual(snapshot?["name"] as? String, "Acme Widget")
        XCTAssertEqual(snapshot?["price"] as? String, "24.50")
        XCTAssertEqual(snapshot?["currency"] as? String, "GBP")
        XCTAssertEqual(snapshot?["brand"] as? String, "Acme")
    }

    func testMicrodataPriceExtracts() {
        let html = """
        <div itemscope itemtype="https://schema.org/Product">
          <span itemprop="name">Acme Widget</span>
          <span itemprop="sku">SKU-42</span>
          <span itemprop="price" content="15.00">$15.00</span>
          <span itemprop="priceCurrency" content="USD"></span>
        </div>
        """
        let snapshot = extract(html: html, urlString: "https://shop.example/products/widget-3")
        XCTAssertEqual(snapshot?["price"] as? String, "15.00")
        XCTAssertEqual(snapshot?["currency"] as? String, "USD")
        XCTAssertEqual(snapshot?["sku"] as? String, "SKU-42")
    }

    func testAmazonURLShapeYieldsARetailerItemID() {
        let html = """
        <script type="application/ld+json">
        {"@type":"Product","name":"Acme Widget","offers":{"price":"9.99","priceCurrency":"USD"}}
        </script>
        """
        let snapshot = extract(html: html, urlString: "https://www.amazon.com/Acme-Widget/dp/B0EXAMPLE1")
        XCTAssertEqual(snapshot?["retailerItemID"] as? String, "B0EXAMPLE1")
        XCTAssertEqual(snapshot?["sku"] as? String, "B0EXAMPLE1")
        XCTAssertEqual(snapshot?["productID"] as? String, "B0EXAMPLE1")
    }

    func testRenderedAmazonPageExtractsWithoutStructuredProductMarkup() {
        let html = """
        <span id="productTitle">Sony WH-1000XM5 Headphones</span>
        <div id="corePriceDisplay_desktop_feature_div">
          <span class="priceToPay"><span class="a-offscreen">$350.97</span></span>
        </div>
        <div id="productOverview_feature_div">
          <table><tr><td>Item model number</td><td>WH1000XM5/B</td></tr>
          <tr><td>Brand</td><td>Sony</td></tr></table>
        </div>
        <img id="landingImage" src="data:image/gif;base64,x"
          data-old-hires="https://m.media-amazon.com/images/I/xm5.jpg">
        """
        let snapshot = extract(
            html: html,
            urlString: "https://www.amazon.com.au/Sony/dp/B09XS7JWHH?tag=affiliate")
        XCTAssertEqual(snapshot?["name"] as? String, "Sony WH-1000XM5 Headphones")
        XCTAssertEqual(snapshot?["price"] as? String, "350.97")
        XCTAssertEqual(snapshot?["currency"] as? String, "AUD")
        XCTAssertEqual(snapshot?["mpn"] as? String, "WH1000XM5/B")
        XCTAssertEqual(snapshot?["sku"] as? String, "B09XS7JWHH")
        XCTAssertEqual(snapshot?["productID"] as? String, "B09XS7JWHH")
        XCTAssertEqual(snapshot?["retailerItemID"] as? String, "B09XS7JWHH")
        XCTAssertEqual(snapshot?["brand"] as? String, "Sony")
        XCTAssertEqual(
            snapshot?["imageURL"] as? String,
            "https://m.media-amazon.com/images/I/xm5.jpg")
    }

    func testAmazonTrackTargetCarriesACompactStructuredHandoff() throws {
        let html = """
        <span id="productTitle">Sony WH-1000XM5 Headphones</span>
        <div id="corePriceDisplay_desktop_feature_div">
          <span class="a-price"><span class="a-offscreen">$350.97</span></span>
        </div>
        <img id="landingImage" data-old-hires="https://m.media-amazon.com/images/I/xm5.jpg">
        """
        js.load(
            html: html,
            urlString: "https://www.amazon.com.au/Sony/dp/B09XS7JWHH",
            scripts: [
                SafariJSTestHarness.newsHosts,
                SafariJSTestHarness.productRules,
                SafariJSTestHarness.contentScript,
            ])
        let handoff = js.string("""
        (function () {
          var snapshot = window.__lunaExtractProductSnapshot();
          return window.__lunaTrackTarget(
            { supportsProducts: true, scheme: "lunapricetracker" }, snapshot
          ).captureHTML();
        })()
        """)

        let unwrapped = try XCTUnwrap(handoff)
        XCTAssertLessThan(unwrapped.utf8.count, 10_000)
        XCTAssertTrue(unwrapped.contains("application/ld+json"))
        XCTAssertTrue(unwrapped.contains("B09XS7JWHH"))
        XCTAssertTrue(unwrapped.contains("xm5.jpg"))
    }

    func testGermanAmazonPriceUsesCommaAsDecimalSeparator() {
        let html = """
        <span id="productTitle">Acme Kaffeeautomat X1000</span>
        <div id="corePriceDisplay_desktop_feature_div">
          <span class="a-price"><span class="a-offscreen">1.299,00 €</span></span>
        </div>
        """
        let snapshot = extract(
            html: html, urlString: "https://www.amazon.de/Acme/dp/B0EXAMPLE2")
        XCTAssertEqual(snapshot?["price"] as? String, "1299")
        XCTAssertEqual(snapshot?["currency"] as? String, "EUR")
        XCTAssertEqual(snapshot?["sku"] as? String, "B0EXAMPLE2")
    }

    func testCanonicalURLStripsTrackingParams() {
        let html = """
        <script type="application/ld+json">
        {"@type":"Product","name":"Acme Widget","offers":{"price":"9.99","priceCurrency":"USD"}}
        </script>
        """
        let snapshot = extract(
            html: html,
            urlString: "https://shop.example/products/widget?utm_source=newsletter&srsltid=abc123")
        XCTAssertEqual(snapshot?["url"] as? String, "https://shop.example/products/widget")
    }

    /// A resolvable NAME but no structured price anywhere -- must still be
    /// null, never a heuristic/rendered-DOM guess ("the price is mandatory").
    func testNoStructuredPriceYieldsNoSnapshotEvenWithAName() {
        let html = """
        <meta property="og:title" content="Acme Widget">
        <h1>Acme Widget</h1><p>Buy now for an unbeatable price!</p>
        """
        XCTAssertNil(extract(html: html, urlString: "https://shop.example/products/widget-4"))
    }
}

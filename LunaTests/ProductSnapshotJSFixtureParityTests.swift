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

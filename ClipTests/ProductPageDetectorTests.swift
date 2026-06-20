//
//  ProductPageDetectorTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

/// Fixture + unit coverage for `ProductPageDetector`: JSON-LD, OpenGraph, and
/// microdata price signals, the Tier-2 heuristic + embedded-JSON price path, plus
/// the pure price/currency parsing primitives. Detection returns a
/// `ProductCandidate`; `staticPrice` is the price found in the static markup.
final class ProductPageDetectorTests: XCTestCase {
    private let detector = ProductPageDetector()

    private func detect(_ fixture: String, url: String) -> ProductCandidate? {
        detector.detect(urlString: url, html: BypassFixtures.html("Products/\(fixture)"))
    }

    // MARK: - Signal coverage

    func testAmazonJSONLD() throws {
        let info = try XCTUnwrap(detect("amazon-jsonld.html", url: "https://www.amazon.com/dp/B09"))
        XCTAssertEqual(info.name, "Anker 715 USB-C Charger (Nano II 65W)")
        XCTAssertEqual(info.staticPrice?.amount, Decimal(string: "45.99"))
        XCTAssertEqual(info.staticPrice?.currency, "USD")
        XCTAssertEqual(info.brand, "Anker")
        XCTAssertEqual(info.productID, "0194644090876")
        XCTAssertEqual(info.imageURL?.absoluteString, "https://m.media-amazon.com/images/I/anker715.jpg")
    }

    func testShopifyOpenGraph() throws {
        let info = try XCTUnwrap(detect("shopify-og.html", url: "https://bellroy.com/products/wallet"))
        XCTAssertEqual(info.name, "The Minimalist Wallet")
        XCTAssertEqual(info.staticPrice?.amount, Decimal(string: "89.00"))
        XCTAssertEqual(info.staticPrice?.currency, "AUD")
        XCTAssertEqual(info.brand, "Bellroy")
        // Protocol-relative og:image resolves against the page URL's scheme.
        XCTAssertEqual(info.imageURL?.absoluteString, "https://cdn.shopify.com/s/files/wallet.jpg")
    }

    func testBestBuyMicrodata() throws {
        let info = try XCTUnwrap(detect("bestbuy-microdata.html", url: "https://www.bestbuy.com/site/6505725.p"))
        XCTAssertEqual(info.name, "Sony WH-1000XM5 Wireless Noise Canceling Headphones")
        XCTAssertEqual(info.staticPrice?.amount, Decimal(string: "399.99"))
        XCTAssertEqual(info.staticPrice?.currency, "USD")
        XCTAssertEqual(info.productID, "6505725")
    }

    func testGenericJSONLDGraphWithAggregateOfferAndEUPrice() throws {
        let info = try XCTUnwrap(detect("generic-jsonld-graph.html", url: "https://coffeegear.example/p/v60"))
        XCTAssertEqual(info.name, "Hario V60 Ceramic Coffee Dripper 02 White")
        XCTAssertEqual(info.staticPrice?.amount, Decimal(string: "23.50"))
        XCTAssertEqual(info.staticPrice?.currency, "EUR")
        XCTAssertEqual(info.brand, "Hario")
        XCTAssertEqual(info.productID, "VDC-02W")
    }

    func testArticleWithoutPriceIsNotAProduct() {
        XCTAssertNil(detect("article-no-price.html", url: "https://news.example/grid"))
    }

    func testEmptyHTMLIsNil() {
        XCTAssertNil(detector.detect(urlString: "https://x.example", html: ""))
    }

    // MARK: - Heuristic detection + embedded-JSON price (Tier 2)

    /// The real Bunnings product page that triggered the bug report: NO structured
    /// price data (no JSON-LD / og:price / itemprop=price / visible "$"), so Tier 1
    /// finds nothing. Heuristic detection must still identify it as a product (add to
    /// cart + rating + retail URL + embedded price = 4 strong signals) and recover
    /// 99 AUD from the __NEXT_DATA__ blob.
    func testBunningsNextDataHeuristicProductWith99AUD() throws {
        let url = "https://www.bunnings.com.au/ryobi-18v-one-25-30cm-cordless-line-trimmer-tool-only_p0208315"
        let info = try XCTUnwrap(detect("bunnings-nextdata.html", url: url))
        XCTAssertEqual(info.name, "Ryobi 18V ONE+ 25/30cm Cordless Line Trimmer - Tool Only")
        XCTAssertEqual(info.staticPrice?.amount, Decimal(99),
                       "The Bunnings price lives statically in __NEXT_DATA__ — recovered with no WebView.")
        XCTAssertEqual(info.staticPrice?.currency, "AUD")
        XCTAssertEqual(
            info.imageURL?.absoluteString,
            "https://media.bunnings.com.au/api/public/content/3982166a37204b0b887bbeb6e6c54547?v=f2c8dc14&t=w1200")
    }

    /// The same fixture must be classified as a PRODUCT, not fall through to the
    /// article/paywall pipeline — the regression the bug report describes.
    func testBunningsIsDetectedAsProductNotArticle() {
        let url = "https://www.bunnings.com.au/ryobi-18v-one-25-30cm-cordless-line-trimmer-tool-only_p0208315"
        XCTAssertNotNil(detect("bunnings-nextdata.html", url: url),
                        "A retail product page must win the product path, not the article/paywall path.")
    }

    /// A normal news article with the same retail-ish URL shape but none of the
    /// product signals must NOT be a product (heuristic doesn't over-fire).
    func testNewsArticleIsNotAProductEvenWithProductishURL() {
        // article-no-price.html has og:type=article, no add-to-cart, no rating, no
        // embedded price. Even at a /products/-shaped URL that's a single weak
        // signal — below the ≥2 threshold.
        XCTAssertNil(detect("article-no-price.html", url: "https://news.example/products/grid-story"))
    }

    func testEmbeddedPriceFromNextDataValueAndCurrencyIso() {
        let node: [String: Any] = [
            "currencyIso": "AUD", "formattedValue": "$99.00",
            "priceAvailable": true, "priceType": "FROM", "value": 99,
        ]
        let price = try? XCTUnwrap(ProductPageDetector.firstPrice(in: node))
        XCTAssertEqual(price?.amount, Decimal(99))
        XCTAssertEqual(price?.currency, "AUD")
    }

    func testEmbeddedPriceIgnoresValuesWithoutPriceContext() {
        // A bare {value: 5} with no price-context key is NOT a price.
        let node: [String: Any] = ["value": 5, "label": "page 5"]
        XCTAssertNil(ProductPageDetector.firstPrice(in: node))
    }

    func testEmbeddedPriceFromSellPriceShape() {
        let node: [String: Any] = ["product": ["sellPrice": "19.99", "priceCurrency": "GBP"]]
        let price = ProductPageDetector.firstPrice(in: node)
        XCTAssertEqual(price?.amount, Decimal(string: "19.99"))
        XCTAssertEqual(price?.currency, "GBP")
    }

    func testProductURLPatterns() {
        XCTAssertTrue(ProductPageDetector.urlLooksLikeProduct(URL(string: "https://x.com/foo_p0208315")))
        XCTAssertTrue(ProductPageDetector.urlLooksLikeProduct(URL(string: "https://amazon.com/dp/B09ABCDE")))
        XCTAssertTrue(ProductPageDetector.urlLooksLikeProduct(URL(string: "https://shop.com/products/wallet")))
        XCTAssertFalse(ProductPageDetector.urlLooksLikeProduct(URL(string: "https://news.com/2024/story")))
        XCTAssertFalse(ProductPageDetector.urlLooksLikeProduct(URL(string: "https://news.com/")))
    }

    // MARK: - Price parsing

    func testParsePriceUSStyle() {
        XCTAssertEqual(ProductPageDetector.parsePrice("$1,234.56"), Decimal(string: "1234.56"))
        XCTAssertEqual(ProductPageDetector.parsePrice("45.99"), Decimal(string: "45.99"))
        XCTAssertEqual(ProductPageDetector.parsePrice("Now 19.00 USD"), Decimal(string: "19.00"))
    }

    func testParsePriceEUStyle() {
        XCTAssertEqual(ProductPageDetector.parsePrice("1.234,56"), Decimal(string: "1234.56"))
        XCTAssertEqual(ProductPageDetector.parsePrice("23,50 €"), Decimal(string: "23.50"))
    }

    func testParsePriceThousandsCommaOnly() {
        XCTAssertEqual(ProductPageDetector.parsePrice("1,299"), Decimal(string: "1299"))
    }

    func testParsePriceRejectsNonNumeric() {
        XCTAssertNil(ProductPageDetector.parsePrice(""))
        XCTAssertNil(ProductPageDetector.parsePrice("free"))
    }

    // MARK: - Currency normalization

    func testNormalizeCurrency() {
        XCTAssertEqual(ProductPageDetector.normalizeCurrency("usd"), "USD")
        XCTAssertEqual(ProductPageDetector.normalizeCurrency("$"), "USD")
        XCTAssertEqual(ProductPageDetector.normalizeCurrency("£"), "GBP")
        XCTAssertEqual(ProductPageDetector.normalizeCurrency("€"), "EUR")
        XCTAssertNil(ProductPageDetector.normalizeCurrency(""))
        XCTAssertNil(ProductPageDetector.normalizeCurrency("dollars"))
    }
}

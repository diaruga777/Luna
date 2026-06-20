//
//  ProductPageDetectorTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

/// Fixture + unit coverage for `ProductPageDetector`: JSON-LD, OpenGraph, and
/// microdata price signals, plus the pure price/currency parsing primitives.
final class ProductPageDetectorTests: XCTestCase {
    private let detector = ProductPageDetector()

    private func detect(_ fixture: String, url: String) -> ProductInfo? {
        detector.detect(urlString: url, html: BypassFixtures.html("Products/\(fixture)"))
    }

    // MARK: - Signal coverage

    func testAmazonJSONLD() throws {
        let info = try XCTUnwrap(detect("amazon-jsonld.html", url: "https://www.amazon.com/dp/B09"))
        XCTAssertEqual(info.name, "Anker 715 USB-C Charger (Nano II 65W)")
        XCTAssertEqual(info.priceAmount, Decimal(string: "45.99"))
        XCTAssertEqual(info.priceCurrency, "USD")
        XCTAssertEqual(info.brand, "Anker")
        XCTAssertEqual(info.productID, "0194644090876")
        XCTAssertEqual(info.imageURL?.absoluteString, "https://m.media-amazon.com/images/I/anker715.jpg")
    }

    func testShopifyOpenGraph() throws {
        let info = try XCTUnwrap(detect("shopify-og.html", url: "https://bellroy.com/products/wallet"))
        XCTAssertEqual(info.name, "The Minimalist Wallet")
        XCTAssertEqual(info.priceAmount, Decimal(string: "89.00"))
        XCTAssertEqual(info.priceCurrency, "AUD")
        XCTAssertEqual(info.brand, "Bellroy")
        // Protocol-relative og:image resolves against the page URL's scheme.
        XCTAssertEqual(info.imageURL?.absoluteString, "https://cdn.shopify.com/s/files/wallet.jpg")
    }

    func testBestBuyMicrodata() throws {
        let info = try XCTUnwrap(detect("bestbuy-microdata.html", url: "https://www.bestbuy.com/site/6505725.p"))
        XCTAssertEqual(info.name, "Sony WH-1000XM5 Wireless Noise Canceling Headphones")
        XCTAssertEqual(info.priceAmount, Decimal(string: "399.99"))
        XCTAssertEqual(info.priceCurrency, "USD")
        XCTAssertEqual(info.productID, "6505725")
    }

    func testGenericJSONLDGraphWithAggregateOfferAndEUPrice() throws {
        let info = try XCTUnwrap(detect("generic-jsonld-graph.html", url: "https://coffeegear.example/p/v60"))
        XCTAssertEqual(info.name, "Hario V60 Ceramic Coffee Dripper 02 White")
        XCTAssertEqual(info.priceAmount, Decimal(string: "23.50"))
        XCTAssertEqual(info.priceCurrency, "EUR")
        XCTAssertEqual(info.brand, "Hario")
        XCTAssertEqual(info.productID, "VDC-02W")
    }

    func testArticleWithoutPriceIsNotAProduct() {
        XCTAssertNil(detect("article-no-price.html", url: "https://news.example/grid"))
    }

    func testEmptyHTMLIsNil() {
        XCTAssertNil(detector.detect(urlString: "https://x.example", html: ""))
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

//
//  ProductPageSuggestionTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

/// Covers the shared-pipeline auto-suggest decision (`ProductPageSuggestion`) and
/// the per-URL debounce (`ProductSuggestionDebouncer`) used by the price-check
/// search overlay. A suggestion exists only when `IngestPipeline` produces a priced
/// product — the same eligibility rule every capture surface uses.
final class ProductPageSuggestionTests: XCTestCase {

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else { fatalError("bad test URL: \(string)") }
        return url
    }

    private func resolve(_ urlString: String, fixture: String) async -> ProductMetadata? {
        await ProductPageSuggestion.resolve(
            url: url(urlString), html: BypassFixtures.html("Products/\(fixture)"))?.metadata
    }

    // MARK: - Unified product + price decision

    func testAmazonProductPageWithPriceIsSuggested() async {
        // The amazon fixture is a product page WITH a buy-box price → suggest, and the
        // resolved metadata carries that exact price (the Add will then succeed).
        let metadata = await resolve(
            "https://www.amazon.com.au/Mrisata/dp/B0CWRSYTTK", fixture: "amazon-dp.html")
        XCTAssertNotNil(metadata)
        XCTAssertEqual(metadata?.price.amount, Decimal(string: "39.99"))
        XCTAssertEqual(metadata?.price.currency, "AUD")
    }

    func testStructuredDataProductPageWithPriceIsSuggested() async {
        // A JSON-LD product page (not a known shop host) still classifies via the
        // heuristic structured-data path and resolves a price → suggest.
        let metadata = await resolve(
            "https://shop.example.com/products/widget", fixture: "shopify-og.html")
        XCTAssertNotNil(metadata)
    }

    func testArticleWithNoPriceIsNotSuggested() async {
        // A no-price page must NOT be suggested — exactly the page whose Add would
        // fail with "couldn't find a price". The two decisions stay in lock-step.
        let metadata = await resolve(
            "https://news.example.com/story", fixture: "article-no-price.html")
        XCTAssertNil(metadata)
    }

    func testProductLookingPageWithoutResolvablePriceIsNotSuggested() async {
        // Even an explicit known-shop URL cannot suggest without a resolved price.
        let metadata = await ProductPageSuggestion.resolve(
            url: url("https://www.amazon.com.au/dp/B0EXAMPLE"),
            html: BypassFixtures.html("Products/article-no-price.html"))
        XCTAssertNil(metadata, "A product URL alone must not suggest without a price")
    }

    // MARK: - Debounce

    func testDebouncerOffersOncePerURL() {
        var debouncer = ProductSuggestionDebouncer()
        let urlString = "https://store.example/p/1"
        XCTAssertFalse(debouncer.hasOffered(urlString: urlString))
        XCTAssertTrue(debouncer.shouldOffer(urlString: urlString), "first time fires")
        XCTAssertTrue(debouncer.hasOffered(urlString: urlString))
        XCTAssertFalse(debouncer.shouldOffer(urlString: urlString), "second time suppressed")
        XCTAssertFalse(debouncer.shouldOffer(urlString: urlString))
    }

    func testDebouncerIsPerURL() {
        var debouncer = ProductSuggestionDebouncer()
        let first = "https://store.example/p/1"
        let second = "https://store.example/p/2"
        XCTAssertTrue(debouncer.shouldOffer(urlString: first))
        XCTAssertTrue(debouncer.shouldOffer(urlString: second), "a different URL still fires")
        XCTAssertFalse(debouncer.shouldOffer(urlString: first), "the first stays suppressed")
    }
}

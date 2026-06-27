//
//  ProductSearchAndExitContextTests.swift
//  ClipTests
//
//  Pure-function coverage for the price-tracker "Search a seller" flow: the Google
//  Shopping / URL-bar URL builders and the per-context navigation / "Read instead"
//  decision.
//

import ClipURLClassification
import ClipModels
import XCTest
@testable import Clip

final class ProductSearchURLTests: XCTestCase {

    // MARK: - Google Shopping URL

    func testGoogleShoppingURLEncodesProductName() {
        let url = ProductSearchURL.googleShoppingURL(forProductName: "Sony WH-1000XM5")
        XCTAssertEqual(
            url?.absoluteString,
            "https://www.google.com/search?tbm=shop&q=Sony+WH-1000XM5")
    }

    func testGoogleShoppingURLEscapesReservedCharacters() {
        let url = ProductSearchURL.googleShoppingURL(forProductName: "Salt & Pepper #1")
        // `&` and `#` must be escaped so they can't break out of the q= value.
        XCTAssertEqual(
            url?.absoluteString,
            "https://www.google.com/search?tbm=shop&q=Salt+%26+Pepper+%231")
    }

    func testGoogleShoppingURLNilForEmptyOrWhitespace() {
        XCTAssertNil(ProductSearchURL.googleShoppingURL(forProductName: ""))
        XCTAssertNil(ProductSearchURL.googleShoppingURL(forProductName: "   \n "))
    }

    // MARK: - URL-bar navigation target

    func testBarTextWithSchemeLoadsThatURL() {
        let url = ProductSearchURL.navigationURL(fromBarText: "https://amazon.com/dp/B0XYZ")
        XCTAssertEqual(url?.absoluteString, "https://amazon.com/dp/B0XYZ")
    }

    func testBarTextBareDomainLoadsOverHTTPS() {
        let url = ProductSearchURL.navigationURL(fromBarText: "bestbuy.com/site/abc")
        XCTAssertEqual(url?.absoluteString, "https://bestbuy.com/site/abc")
    }

    func testBarTextFreeTextBecomesGoogleSearch() {
        let url = ProductSearchURL.navigationURL(fromBarText: "wireless headphones")
        XCTAssertEqual(url?.absoluteString, "https://www.google.com/search?q=wireless+headphones")
    }

    func testBarTextEmptyIsNil() {
        XCTAssertNil(ProductSearchURL.navigationURL(fromBarText: "   "))
    }
}

final class PriceTrackingExitContextTests: XCTestCase {

    // MARK: - Left button (host)

    func testInAppHostShowsBack() {
        let context = PriceTrackingExitContext(host: .inApp, entry: .existing)
        XCTAssertEqual(context.leftButton, .back)
    }

    func testExtensionHostShowsDone() {
        let context = PriceTrackingExitContext(host: .extension, entry: .creation)
        XCTAssertEqual(context.leftButton, .done)
    }

    // MARK: - Read instead (entry)

    func testCreationShowsDiscardTracker() {
        let context = PriceTrackingExitContext(host: .inApp, entry: .creation)
        XCTAssertEqual(context.readInsteadAction, .discardTracker)
    }

    func testMergeRevertsExactlyTheAddedURL() {
        let added = "https://store.example/p/123"
        let context = PriceTrackingExitContext(
            host: .inApp, entry: .merge(addedStoreURLString: added))
        XCTAssertEqual(context.readInsteadAction, .revertAddedStore(urlString: added))
    }

    func testExistingHidesReadInstead() {
        let context = PriceTrackingExitContext(host: .inApp, entry: .existing)
        XCTAssertEqual(context.readInsteadAction, .hidden)
        // Hidden regardless of host — returning to a saved tracker is never save-time.
        let extContext = PriceTrackingExitContext(host: .extension, entry: .existing)
        XCTAssertEqual(extContext.readInsteadAction, .hidden)
    }
}

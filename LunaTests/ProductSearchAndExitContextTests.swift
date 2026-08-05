//
//  ProductSearchAndExitContextTests.swift
//  LunaTests
//
//  Pure-function coverage for the price-tracker "Search a seller" flow: the Google
//  Shopping / URL-bar URL builders and the per-context navigation / "Read instead"
//  decision.
//

import LunaURLClassification
import LunaModels
import XCTest
@testable import Luna

final class ProductSearchURLTests: XCTestCase {

    // MARK: - Google Shopping URL

    func testGoogleShoppingURL() {
        let cases: [(name: String, productName: String, expected: String?)] = [
            ("plain name", "Sony WH-1000XM5",
             "https://www.google.com/search?tbm=shop&q=Sony+WH-1000XM5"),
            // `&` and `#` must be escaped so they can't break out of the q= value.
            ("reserved characters escaped", "Salt & Pepper #1",
             "https://www.google.com/search?tbm=shop&q=Salt+%26+Pepper+%231"),
            ("empty", "", nil),
            ("whitespace only", "   \n ", nil),
        ]

        for testCase in cases {
            XCTAssertEqual(
                ProductSearchURL.googleShoppingURL(
                    forProductName: testCase.productName)?.absoluteString,
                testCase.expected,
                testCase.name)
        }
    }

    // MARK: - URL-bar navigation target

    func testNavigationURLFromBarText() {
        let cases: [(name: String, barText: String, expected: String?)] = [
            ("explicit scheme loads that URL", "https://amazon.com/dp/B0XYZ",
             "https://amazon.com/dp/B0XYZ"),
            ("bare domain loads over HTTPS", "bestbuy.com/site/abc",
             "https://bestbuy.com/site/abc"),
            ("free text becomes a Google search", "wireless headphones",
             "https://www.google.com/search?q=wireless+headphones"),
            ("empty is nil", "   ", nil),
        ]

        for testCase in cases {
            XCTAssertEqual(
                ProductSearchURL.navigationURL(fromBarText: testCase.barText)?.absoluteString,
                testCase.expected,
                testCase.name)
        }
    }
}

final class PriceTrackingExitContextTests: XCTestCase {

    // MARK: - Left button (host)

    func testLeftButtonFollowsTheHost() {
        let cases: [(name: String, context: PriceTrackingExitContext,
                     expected: PriceTrackingLeftButton)] = [
            ("in-app host shows Back",
             PriceTrackingExitContext(host: .inApp, entry: .existing), .back),
            ("extension host shows Done",
             PriceTrackingExitContext(host: .extension, entry: .creation), .done),
        ]

        for testCase in cases {
            XCTAssertEqual(testCase.context.leftButton, testCase.expected, testCase.name)
        }
    }

    // MARK: - Read instead (entry)

    func testReadInsteadActionFollowsTheEntry() {
        let added = "https://store.example/p/123"
        let cases: [(name: String, context: PriceTrackingExitContext,
                     expected: PriceTrackingReadInsteadAction)] = [
            ("creation discards the tracker",
             PriceTrackingExitContext(host: .inApp, entry: .creation), .discardTracker),
            ("merge reverts exactly the added URL",
             PriceTrackingExitContext(host: .inApp, entry: .merge(addedStoreURLString: added)),
             .revertAddedStore(urlString: added)),
            // Hidden regardless of host — returning to a saved tracker is never save-time.
            ("existing hides it (in-app)",
             PriceTrackingExitContext(host: .inApp, entry: .existing), .hidden),
            ("existing hides it (extension)",
             PriceTrackingExitContext(host: .extension, entry: .existing), .hidden),
        ]

        for testCase in cases {
            XCTAssertEqual(testCase.context.readInsteadAction, testCase.expected, testCase.name)
        }
    }
}

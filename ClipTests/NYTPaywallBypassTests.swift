//
//  NYTPaywallBypassTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

/// Covers the pure NYT trailing-dot URL transform used as the first paywall-bypass
/// attempt in the archive reader.
final class NYTPaywallBypassTests: XCTestCase {

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else { fatalError("bad test URL: \(string)") }
        return url
    }

    func testAddsTrailingDotToHostPreservingPathAndQuery() {
        XCTAssertEqual(
            NYTPaywallBypass.trailingDotURL(for: url("https://www.nytimes.com/2026/06/20/world/story.html?smid=x"))?
                .absoluteString,
            "https://www.nytimes.com./2026/06/20/world/story.html?smid=x")
    }

    func testApexHost() {
        XCTAssertEqual(
            NYTPaywallBypass.trailingDotURL(for: url("https://nytimes.com/article"))?.absoluteString,
            "https://nytimes.com./article")
    }

    func testSubdomainHost() {
        XCTAssertEqual(
            NYTPaywallBypass.trailingDotURL(for: url("https://cooking.nytimes.com/recipes/123"))?.absoluteString,
            "https://cooking.nytimes.com./recipes/123")
    }

    func testNytComAlias() {
        XCTAssertEqual(
            NYTPaywallBypass.trailingDotURL(for: url("https://www.nyt.com/x"))?.host,
            "www.nyt.com.")
    }

    func testNonNYTReturnsNil() {
        XCTAssertNil(NYTPaywallBypass.trailingDotURL(for: url("https://www.wsj.com/articles/x")))
        XCTAssertNil(NYTPaywallBypass.trailingDotURL(for: url("https://notnytimes.com.evil.com/x")))
    }

    func testAlreadyDottedReturnsNil() {
        XCTAssertNil(NYTPaywallBypass.trailingDotURL(for: url("https://www.nytimes.com./article")))
    }

    func testHostClassification() {
        XCTAssertTrue(NYTPaywallBypass.isNYTHost("www.nytimes.com"))
        XCTAssertTrue(NYTPaywallBypass.isNYTHost("nytimes.com"))
        XCTAssertTrue(NYTPaywallBypass.isNYTHost("cooking.nytimes.com"))
        XCTAssertTrue(NYTPaywallBypass.isNYTHost("nytimes.com."))
        XCTAssertFalse(NYTPaywallBypass.isNYTHost("wsj.com"))
        XCTAssertFalse(NYTPaywallBypass.isNYTHost("notnytimes.com.attacker.com"))
    }
}

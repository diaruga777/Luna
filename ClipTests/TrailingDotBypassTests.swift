//
//  TrailingDotBypassTests.swift
//  ClipTests
//

import ClipPaywallBypass
import XCTest
@testable import Clip

/// Covers the pure trailing-dot URL transform. Generalized from the former
/// NYT-only bypass: the transform now applies to ANY host (the selector decides
/// when to use it), so these assert the transform itself plus the retained NYT
/// host classification used by the rule table.
final class TrailingDotBypassTests: XCTestCase {

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else { fatalError("bad test URL: \(string)") }
        return url
    }

    func testAddsTrailingDotToHostPreservingPathAndQuery() {
        XCTAssertEqual(
            TrailingDotBypass.trailingDotURL(for: url("https://www.nytimes.com/2026/06/20/world/story.html?smid=x"))?
                .absoluteString,
            "https://www.nytimes.com./2026/06/20/world/story.html?smid=x")
    }

    func testApexHost() {
        XCTAssertEqual(
            TrailingDotBypass.trailingDotURL(for: url("https://nytimes.com/article"))?.absoluteString,
            "https://nytimes.com./article")
    }

    func testSubdomainHost() {
        XCTAssertEqual(
            TrailingDotBypass.trailingDotURL(for: url("https://cooking.nytimes.com/recipes/123"))?.absoluteString,
            "https://cooking.nytimes.com./recipes/123")
    }

    /// Now generalized: a non-NYT host IS transformed (the host guard was dropped).
    func testNonNYTHostIsTransformed() {
        XCTAssertEqual(
            TrailingDotBypass.trailingDotURL(for: url("https://www.wsj.com/articles/x"))?.absoluteString,
            "https://www.wsj.com./articles/x")
        XCTAssertEqual(
            TrailingDotBypass.trailingDotURL(for: url("https://www.bloomberg.com/news/y"))?.host,
            "www.bloomberg.com.")
    }

    func testAlreadyDottedReturnsNil() {
        XCTAssertNil(TrailingDotBypass.trailingDotURL(for: url("https://www.nytimes.com./article")))
        XCTAssertNil(TrailingDotBypass.trailingDotURL(for: url("https://www.wsj.com./articles/x")))
    }

    func testHostClassification() {
        XCTAssertTrue(TrailingDotBypass.isNYTHost("www.nytimes.com"))
        XCTAssertTrue(TrailingDotBypass.isNYTHost("nytimes.com"))
        XCTAssertTrue(TrailingDotBypass.isNYTHost("cooking.nytimes.com"))
        XCTAssertTrue(TrailingDotBypass.isNYTHost("nytimes.com."))
        XCTAssertFalse(TrailingDotBypass.isNYTHost("wsj.com"))
        XCTAssertFalse(TrailingDotBypass.isNYTHost("notnytimes.com.attacker.com"))
    }
}

//
//  URLPrefixMatchTests.swift
//  LunaTests
//

import LunaIntents
import XCTest
@testable import Luna

final class URLPrefixMatchTests: XCTestCase {

    func testMatches() {
        let cases: [(provided: String, tracked: String)] = [
            ("https://example.com", "https://example.com/article/1"),
            ("http://example.com/", "https://www.example.com/article"),
            ("https://WWW.Example.com/Article", "https://example.com/article"),
            ("example.com", "https://example.com/x"),
            // Provided more specific than tracked also passes (either-prefix).
            ("https://example.com/article/1", "https://example.com"),
            ("https://example.com/a/", "https://example.com/a"),
        ]
        for testCase in cases {
            XCTAssertTrue(
                URLPrefixMatch.fuzzyPrefixMatches(
                    provided: testCase.provided, tracked: testCase.tracked),
                "expected match: \(testCase.provided) vs \(testCase.tracked)")
        }
    }

    func testMismatches() {
        let cases: [(provided: String, tracked: String)] = [
            ("https://other.com", "https://example.com/article"),
            ("https://example.org", "https://example.com"),
            ("https://example.com/blog", "https://example.com/article"),
            ("", "https://example.com"),
        ]
        for testCase in cases {
            XCTAssertFalse(
                URLPrefixMatch.fuzzyPrefixMatches(
                    provided: testCase.provided, tracked: testCase.tracked),
                "expected mismatch: \(testCase.provided) vs \(testCase.tracked)")
        }
    }
}

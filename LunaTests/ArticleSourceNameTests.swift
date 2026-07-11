//
//  ArticleSourceNameTests.swift
//  LunaTests
//

import LunaIntents
import XCTest

final class ArticleSourceNameTests: XCTestCase {

    // MARK: - host(fromURLString:)

    func testHostStripsWWW() {
        XCTAssertEqual(ArticleSourceName.host(fromURLString: "https://www.theatlantic.com/article"), "theatlantic.com")
    }

    func testHostLowercased() {
        XCTAssertEqual(ArticleSourceName.host(fromURLString: "https://TheAtlantic.COM/x"), "theatlantic.com")
    }

    func testHostNilForSyntheticScheme() {
        XCTAssertNil(ArticleSourceName.host(fromURLString: "lunadoc://abc-123"))
    }

    func testHostNilForUnparsableString() {
        XCTAssertNil(ArticleSourceName.host(fromURLString: ""))
    }

    // MARK: - humanReadable(host:)

    func testHumanReadableSplitsLeadingThe() {
        XCTAssertEqual(ArticleSourceName.humanReadable(host: "theatlantic.com"), "the atlantic")
    }

    func testHumanReadableSplitsLeadingTheForOtherSites() {
        XCTAssertEqual(ArticleSourceName.humanReadable(host: "thehill.com"), "the hill")
        XCTAssertEqual(ArticleSourceName.humanReadable(host: "theverge.com"), "the verge")
    }

    func testHumanReadableSplitsHyphens() {
        XCTAssertEqual(ArticleSourceName.humanReadable(host: "new-york-times.com"), "new york times")
    }

    func testHumanReadableHandlesMultiPartTLD() {
        XCTAssertEqual(ArticleSourceName.humanReadable(host: "bbc.co.uk"), "bbc")
    }

    func testHumanReadableStripsWWWDefensively() {
        XCTAssertEqual(ArticleSourceName.humanReadable(host: "www.theatlantic.com"), "the atlantic")
    }

    func testHumanReadableNoSpecialCaseWhenNoThePrefix() {
        XCTAssertEqual(ArticleSourceName.humanReadable(host: "nytimes.com"), "nytimes")
    }
}

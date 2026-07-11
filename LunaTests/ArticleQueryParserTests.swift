//
//  ArticleQueryParserTests.swift
//  LunaTests
//

import LunaIntents
import XCTest

final class ArticleQueryParserTests: XCTestCase {

    func testTokenizeSplitsOnNonAlphanumerics() {
        XCTAssertEqual(
            ArticleQueryParser.tokenize("The Atlantic's Boston piece!"),
            ["the", "atlantic", "s", "boston", "piece"])
    }

    func testNormalizeFoldsCaseAndDiacritics() {
        XCTAssertEqual(ArticleQueryParser.normalize("CAFÉ Society"), "cafe society")
    }

    func testParseExtractsYesterday() {
        let parsed = ArticleQueryParser.parse("from yesterday")
        XCTAssertEqual(parsed.dateFilter, .yesterday)
        XCTAssertEqual(parsed.textTokens, ["from"])
    }

    func testParseExtractsToday() {
        let parsed = ArticleQueryParser.parse("today")
        XCTAssertEqual(parsed.dateFilter, .today)
        XCTAssertEqual(parsed.textTokens, [])
    }

    func testParseExtractsThisWeekBeforeToday() {
        // "this week" contains no standalone "today", but make sure the
        // longest-phrase-first order doesn't leave a stray "week" token.
        let parsed = ArticleQueryParser.parse("articles from this week")
        XCTAssertEqual(parsed.dateFilter, .thisWeek)
        XCTAssertEqual(parsed.textTokens, ["articles", "from"])
    }

    func testParseWithNoDatePhraseLeavesFilterNil() {
        let parsed = ArticleQueryParser.parse("about Boston")
        XCTAssertNil(parsed.dateFilter)
        XCTAssertEqual(parsed.textTokens, ["about", "boston"])
    }

    func testParseIsCaseInsensitive() {
        let parsed = ArticleQueryParser.parse("Yesterday")
        XCTAssertEqual(parsed.dateFilter, .yesterday)
    }
}

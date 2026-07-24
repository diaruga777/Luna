//
//  IntentQueryTests.swift
//  LunaTests
//

import LunaIntents
import LunaIntents
import XCTest
@testable import Luna

final class IntentQueryTests: XCTestCase {

    func testRedditQueryUsesOperatorsAndStripsPrefixes() {
        let query = RedditPostQuery.searchQuery(
            subreddit: "r/swift", title: "Concurrency tips", author: "u/bob")
        XCTAssertEqual(query, "Concurrency tips subreddit:swift author:bob")
    }

    func testRedditQueryWithoutAuthor() {
        let query = RedditPostQuery.searchQuery(subreddit: "swift", title: "Hello", author: nil)
        XCTAssertEqual(query, "Hello subreddit:swift")
    }

    func testRedditQueryEmptyTitleIsEmpty() {
        XCTAssertEqual(RedditPostQuery.searchQuery(subreddit: "swift", title: "  ", author: "x"), "")
    }

    func testBlueskyQueryUsesFromOperator() {
        let query = BlueskyPostQuery.searchQuery(handle: "@jay.bsky.team", text: "hello world")
        XCTAssertEqual(query, "hello world from:jay.bsky.team")
    }

    func testBlueskyQueryTextOnly() {
        XCTAssertEqual(BlueskyPostQuery.searchQuery(handle: "  ", text: "just text"), "just text")
    }

    // MARK: - Save-intent single-string response parsing

    func testParseFieldsSplitsOnDelimiterAndTrims() {
        XCTAssertEqual(
            SaveResponseParsing.parseFields(from: "Veritasium ; The math of slime"),
            ["Veritasium", "The math of slime"])
        XCTAssertEqual(
            SaveResponseParsing.parseFields(from: "  swift  ;  Concurrency tips ;  bob "),
            ["swift", "Concurrency tips", "bob"])
    }

    func testParseFieldsTreatsNoneAndEmptyAsNothing() {
        XCTAssertEqual(SaveResponseParsing.parseFields(from: "none"), [])
        XCTAssertEqual(SaveResponseParsing.parseFields(from: "  NONE  "), [])
        XCTAssertEqual(SaveResponseParsing.parseFields(from: ""), [])
        XCTAssertEqual(SaveResponseParsing.parseFields(from: "   "), [])
        XCTAssertEqual(SaveResponseParsing.parseFields(from: nil), [])
    }

    func testParseFieldsSingleValuePassesThrough() {
        XCTAssertEqual(
            SaveResponseParsing.parseFields(from: "https://example.com/a"),
            ["https://example.com/a"])
    }
}

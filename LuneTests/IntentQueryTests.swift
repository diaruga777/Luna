//
//  IntentQueryTests.swift
//  LuneTests
//

import LuneIntents
import LunePlatforms
import XCTest
@testable import Lune

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

    // MARK: - SaveFromApp single-string parsing

    func testParseFieldsSplitsOnDelimiterAndTrims() {
        XCTAssertEqual(
            SaveFromAppIntent.parseFields(from: "Veritasium ; The math of slime"),
            ["Veritasium", "The math of slime"])
        XCTAssertEqual(
            SaveFromAppIntent.parseFields(from: "  swift  ;  Concurrency tips ;  bob "),
            ["swift", "Concurrency tips", "bob"])
    }

    func testParseFieldsTreatsNoneAndEmptyAsNothing() {
        XCTAssertEqual(SaveFromAppIntent.parseFields(from: "none"), [])
        XCTAssertEqual(SaveFromAppIntent.parseFields(from: "  NONE  "), [])
        XCTAssertEqual(SaveFromAppIntent.parseFields(from: ""), [])
        XCTAssertEqual(SaveFromAppIntent.parseFields(from: "   "), [])
        XCTAssertEqual(SaveFromAppIntent.parseFields(from: nil), [])
    }

    func testParseFieldsSingleValuePassesThrough() {
        XCTAssertEqual(
            SaveFromAppIntent.parseFields(from: "https://example.com/a"),
            ["https://example.com/a"])
    }
}

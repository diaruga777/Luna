//
//  IntentQueryTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

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
}

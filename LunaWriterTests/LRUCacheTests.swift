//
//  LRUCacheTests.swift
//  LunaWriterTests
//

import XCTest
@testable import LunaWriterText

/// Pins the eviction and recency rules the segmenters and the tagger lean
/// on: a cache full of stale answers is worse than no cache at all.
final class LRUCacheTests: XCTestCase {

    func testInsertingBeyondTheLimitEvictsTheLeastRecentlyUsedKey() {
        var cache = LRUCache<String, Int>(limit: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        cache.insert(3, for: "c")
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.value(for: "a"))
        XCTAssertEqual(cache.value(for: "b"), 2)
        XCTAssertEqual(cache.value(for: "c"), 3)
    }

    func testReadingAKeyPromotesItSoItSurvivesTheNextEviction() {
        var cache = LRUCache<String, Int>(limit: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        _ = cache.value(for: "a")
        cache.insert(3, for: "c")
        XCTAssertEqual(cache.value(for: "a"), 1)
        XCTAssertNil(cache.value(for: "b"))
        XCTAssertEqual(cache.value(for: "c"), 3)
    }

    func testReinsertingAnExistingKeyAlsoCountsAsAUse() {
        var cache = LRUCache<String, Int>(limit: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        cache.insert(10, for: "a")
        cache.insert(3, for: "c")
        XCTAssertEqual(cache.value(for: "a"), 10)
        XCTAssertNil(cache.value(for: "b"))
    }

    func testRemoveAllClearsEveryEntry() {
        var cache = LRUCache<String, Int>(limit: 4)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.value(for: "a"))
        XCTAssertNil(cache.value(for: "b"))
    }

    func testALimitBelowOneStillHoldsOneEntry() {
        var cache = LRUCache<String, Int>(limit: 0)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.value(for: "b"), 2)
    }
}

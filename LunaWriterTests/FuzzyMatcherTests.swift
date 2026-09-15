//
//  FuzzyMatcherTests.swift
//  LunaWriterTests
//

import XCTest
@testable import LunaWriterText

final class FuzzyMatcherTests: XCTestCase {

    func testAnExactMatchScoresOneAndStrongerFormsOutrankWeakerOnes() throws {
        XCTAssertEqual(FuzzyMatcher.score(query: "Bold", candidate: "bold"), 1)
        let word = try XCTUnwrap(FuzzyMatcher.score(query: "list", candidate: "Bullet List"))
        let prefix = try XCTUnwrap(FuzzyMatcher.score(query: "bul", candidate: "Bullet List"))
        let wordPrefix = try XCTUnwrap(FuzzyMatcher.score(query: "lis", candidate: "Bullet List"))
        let substring = try XCTUnwrap(FuzzyMatcher.score(query: "ullet", candidate: "Bullet List"))
        let subsequence = try XCTUnwrap(FuzzyMatcher.score(query: "blt", candidate: "Bullet List"))
        XCTAssertGreaterThan(word, prefix)
        XCTAssertGreaterThan(prefix, wordPrefix)
        XCTAssertGreaterThan(wordPrefix, substring)
        XCTAssertGreaterThan(substring, subsequence)
        XCTAssertGreaterThanOrEqual(subsequence, FuzzyMatcher.subsequenceFloor)
    }

    func testLettersOutOfOrderOrMissingDoNotMatch() {
        XCTAssertNil(FuzzyMatcher.score(query: "tlb", candidate: "Bullet List"))
        XCTAssertNil(FuzzyMatcher.score(query: "bulletz", candidate: "Bullet List"))
        XCTAssertNil(FuzzyMatcher.score(query: "", candidate: "Bullet List"))
    }

    func testEveryQueryTokenMustMatchAndTheWeakestDeterminesStrength() throws {
        let both = try XCTUnwrap(FuzzyMatcher.score(query: "new chap", candidate: "New chapter"))
        XCTAssertEqual(both, 0.8, accuracy: 0.001)
        XCTAssertNil(FuzzyMatcher.score(query: "new idea", candidate: "New chapter"))
    }

    func testCommonWordsCannotPromoteScatteredLettersIntoAStrongMatch() throws {
        let score = try XCTUnwrap(FuzzyMatcher.score(
            query: "a new idea", candidate: "Upwards White Arrow On Pedestal With Horizontal Bar"))
        XCTAssertLessThan(score, 0.4)
    }

    func testDiacriticsCaseAndPunctuationAreIgnored() {
        XCTAssertEqual(FuzzyMatcher.score(query: "em-dash", candidate: "Em Dash"), 1)
        XCTAssertEqual(FuzzyMatcher.score(query: "ÉPSILON", candidate: "epsilon"), 1)
    }

    func testARunTogetherWordStillFindsItsSpacedName() throws {
        let score = try XCTUnwrap(FuzzyMatcher.score(query: "emdash", candidate: "Em Dash"))
        XCTAssertGreaterThanOrEqual(score, FuzzyMatcher.subsequenceFloor)
    }

    func testRankSortsByBestSearchStringDropsBelowMinimumAndKeepsListOrderOnTies() {
        let items = [("a", ["Numbered List"]), ("b", ["Bold", "strong"]), ("c", ["Bullet List"]), ("d", ["Quote"])]
        let ranked = FuzzyMatcher.rank(items, query: "list", minimum: 0.5, limit: 10) { $0.1 }
        XCTAssertEqual(ranked.map { $0.item.0 }, ["a", "c"])
        let strong = FuzzyMatcher.rank(items, query: "strong") { $0.1 }
        XCTAssertEqual(strong.map { $0.item.0 }, ["b"])
        XCTAssertEqual(FuzzyMatcher.rank(items, query: "list", limit: 1) { $0.1 }.count, 1)
    }
}

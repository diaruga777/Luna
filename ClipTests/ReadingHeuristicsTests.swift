//
//  ReadingHeuristicsTests.swift
//  ClipTests
//

import ClipReaderEngine
import XCTest
@testable import Clip

final class ReadingHeuristicsTests: XCTestCase {

    func testCoreStripsPunctuationAndCase() {
        XCTAssertEqual(ReadingHeuristics.core("The,"), "the")
        XCTAssertEqual(ReadingHeuristics.core("(House)"), "house")
        XCTAssertEqual(ReadingHeuristics.core("don't"), "don't")
    }

    func testClassifiesFunctionWords() {
        XCTAssertTrue(ReadingHeuristics.isLeadingBinder("the"))
        XCTAssertTrue(ReadingHeuristics.isLeadingBinder("The,"))
        XCTAssertFalse(ReadingHeuristics.isLeadingBinder("cat"))

        XCTAssertTrue(ReadingHeuristics.isPhraseStarter("over"))
        XCTAssertTrue(ReadingHeuristics.isPhraseStarter("because"))
        XCTAssertFalse(ReadingHeuristics.isPhraseStarter("running"))

        XCTAssertTrue(ReadingHeuristics.isFunctionWord("of"))
        XCTAssertFalse(ReadingHeuristics.isFunctionWord("elephant"))
    }

    func testSyllableEstimateIsRoughlyRight() {
        XCTAssertEqual(ReadingHeuristics.syllableEstimate("cat"), 1)
        XCTAssertEqual(ReadingHeuristics.syllableEstimate("make"), 1) // silent trailing e
        XCTAssertEqual(ReadingHeuristics.syllableEstimate("water"), 2)
        XCTAssertGreaterThanOrEqual(ReadingHeuristics.syllableEstimate("extraordinary"), 4)
    }

    func testDifficultyOrdersWords() {
        // Function words are the quickest.
        XCTAssertLessThan(
            ReadingHeuristics.difficultyFactor("the"),
            ReadingHeuristics.difficultyFactor("cat"))
        // Long, multi-syllable words are the slowest.
        XCTAssertGreaterThan(
            ReadingHeuristics.difficultyFactor("extraordinary"),
            ReadingHeuristics.difficultyFactor("cat"))
        // Numbers get a dwell bump.
        XCTAssertGreaterThan(
            ReadingHeuristics.difficultyFactor("2026"),
            ReadingHeuristics.difficultyFactor("the"))
    }
}

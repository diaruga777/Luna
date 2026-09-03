//
//  WriterStatisticsTests.swift
//  LunaTests
//

import XCTest
import LunaWriterText

/// Pins the counts the writer watches while writing and the goal checks
/// against. The interesting cases are the ones a naive split gets wrong: a
/// decimal point, a contraction, an abbreviation, and a blank line.
final class WriterStatisticsTests: XCTestCase {

    private func measure(_ text: String) -> TextStatistics.Stats {
        TextStatistics.measure(text)
    }

    func testWordsCountContractionsHyphensAndDecimalsOnce() {
        XCTAssertEqual(measure("Don't stop well-known things").words, 4)
        XCTAssertEqual(measure("It costs $1.50 today").words, 4)
        XCTAssertEqual(measure("Ship 1,200 boxes").words, 3)
    }

    func testCharactersCountWithAndWithoutSpaces() {
        let stats = measure("ab cd\nef")
        XCTAssertEqual(stats.characters, 8)
        XCTAssertEqual(stats.charactersWithoutSpaces, 6)
    }

    func testSentencesEndAtAStopFollowedBySpace() {
        XCTAssertEqual(measure("One. Two! Three? Four").sentences, 4)
        XCTAssertEqual(measure("Only one sentence").sentences, 1)
        XCTAssertEqual(measure("He said \"stop.\" Then left.").sentences, 2)
    }

    func testDecimalPointAndAbbreviationDoNotEndASentence() {
        XCTAssertEqual(measure("It costs $1.50 today. Fine.").sentences, 2)
        XCTAssertEqual(measure("Dr. Smith went home. He slept.").sentences, 2)
    }

    func testParagraphsAreRunsOfLinesBetweenBlankLines() {
        XCTAssertEqual(measure("one\ntwo\n\nthree\n\n\nfour\n").paragraphs, 3)
        XCTAssertEqual(measure("single line with no break").paragraphs, 1)
        XCTAssertEqual(measure("  \n\n   \n").paragraphs, 0)
    }

    func testReadingTimeFollowsTheWordCount() {
        let stats = TextStatistics.measure(String(repeating: "word ", count: 119), wordsPerMinute: 238)
        XCTAssertEqual(stats.words, 119)
        XCTAssertEqual(stats.readingTime, 30, accuracy: 0.001)
    }

    func testMeasuringARangeCountsOnlyThatRange() {
        let text = "skip this. Count these words."
        let range = NSRange(location: 11, length: (text as NSString).length - 11)
        XCTAssertEqual(TextStatistics.measure(text, range: range).words, 3)
        XCTAssertEqual(TextStatistics.measure(text, range: range).sentences, 1)
    }

    func testEmptyTextCountsNothing() {
        XCTAssertEqual(measure(""), TextStatistics.Stats())
        XCTAssertEqual(measure("   \n  ").words, 0)
        XCTAssertEqual(measure("   \n  ").sentences, 0)
    }
}

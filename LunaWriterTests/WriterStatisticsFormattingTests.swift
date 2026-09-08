//
//  WriterStatisticsFormattingTests.swift
//  LunaWriterTests
//

import XCTest
@testable import LunaWriterEditor
import LunaWriterModels
import LunaWriterText

/// The goal ring reads the writing against whichever unit the goal names.
final class WriterStatisticsFormattingTests: XCTestCase {

    private func stats(words: Int = 0, characters: Int = 0, sentences: Int = 0, readingTime: TimeInterval = 0)
        -> TextStatistics.Stats
    {
        TextStatistics.Stats(
            words: words, characters: characters, charactersWithoutSpaces: characters,
            sentences: sentences, paragraphs: 1, readingTime: readingTime)
    }

    func testEachGoalUnitReadsItsOwnCount() {
        let measured = stats(words: 120, characters: 700, sentences: 9, readingTime: 150)
        XCTAssertEqual(StatisticsFormatting.measure(measured, in: .words), 120)
        XCTAssertEqual(StatisticsFormatting.measure(measured, in: .characters), 700)
        XCTAssertEqual(StatisticsFormatting.measure(measured, in: .sentences), 9)
        XCTAssertEqual(StatisticsFormatting.measure(measured, in: .readingMinutes), 3)
    }

    func testProgressIsTheFractionOfTheTarget() {
        let goal = WritingGoal(unit: .words, target: 400)
        XCTAssertEqual(StatisticsFormatting.fraction(of: stats(words: 100), against: goal), 0.25, accuracy: 0.001)
    }

    func testProgressStopsAtTheTarget() {
        let goal = WritingGoal(unit: .words, target: 400)
        XCTAssertEqual(StatisticsFormatting.fraction(of: stats(words: 900), against: goal), 1, accuracy: 0.001)
    }

    func testAnEmptyTargetNeverDividesByZero() {
        let goal = WritingGoal(unit: .words, target: 0)
        XCTAssertEqual(StatisticsFormatting.fraction(of: stats(words: 12), against: goal), 0)
    }

    func testReadingTimeRoundsUpToAWholeMinute() {
        XCTAssertEqual(StatisticsFormatting.readingTime(10), StatisticsFormatting.readingTime(59))
        XCTAssertNotEqual(StatisticsFormatting.readingTime(59), StatisticsFormatting.readingTime(61))
    }
}

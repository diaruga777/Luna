//
//  GoalProgressTests.swift
//  LunaTests
//

import XCTest
@testable import LunaWriterLibraryUI
import LunaWriterModels

/// organiser #23: `.sentences` and `.readingMinutes` used to compare the
/// target against `wordCount`, so a 30-sentence goal read words against 30
/// and a 5-minute goal read words against 5. Table-driven over all four
/// units and all three modes.
final class GoalProgressTests: XCTestCase {

    private func makeDocument(wordCount: Int, characterCount: Int, sentenceCount: Int) -> WriterDocument {
        var document = WriterDocument(
            groupID: GroupID(), wordCount: wordCount, characterCount: characterCount)
        document.sentenceCount = sentenceCount
        return document
    }

    func testProgressAcrossEveryUnitAndMode() {
        // 750 words / 4000 characters / 15 sentences → 750 / 250 = 3 reading minutes.
        let document = makeDocument(wordCount: 750, characterCount: 4000, sentenceCount: 15)

        let cases: [(unit: WritingGoal.Unit, mode: WritingGoal.Mode, target: Int, expected: Float)] = [
            // .atLeast / .about: min(1, count / target).
            (.words, .atLeast, 1000, 0.75),
            (.words, .about, 500, 1.0),
            (.characters, .atLeast, 8000, 0.5),
            (.characters, .about, 4000, 1.0),
            (.sentences, .atLeast, 30, 0.5),
            (.sentences, .about, 10, 1.0),
            (.readingMinutes, .atLeast, 6, 0.5),
            (.readingMinutes, .about, 2, 1.0),
            // .atMost: 1.0 at or under the ceiling, target / count over it.
            (.words, .atMost, 1000, 1.0),
            (.characters, .atMost, 2000, 0.5),
            (.sentences, .atMost, 30, 1.0),
            (.readingMinutes, .atMost, 1, 1.0 / 3.0),
        ]

        for testCase in cases {
            let goal = WritingGoal(unit: testCase.unit, target: testCase.target, mode: testCase.mode)
            let progress = SheetCell.progress(for: document, goal: goal)
            XCTAssertEqual(
                progress, testCase.expected, accuracy: 0.001,
                "unit \(testCase.unit) mode \(testCase.mode) target \(testCase.target)")
        }
    }

    func testReadingMinutesRoundsDownAtTwoHundredFiftyWordsPerMinute() {
        // 499 words is still 1 reading minute (integer division), not 2.
        let document = makeDocument(wordCount: 499, characterCount: 0, sentenceCount: 0)
        let goal = WritingGoal(unit: .readingMinutes, target: 1, mode: .atLeast)
        XCTAssertEqual(SheetCell.progress(for: document, goal: goal), 1.0, accuracy: 0.001)
    }

    func testZeroTargetIsZeroProgressRegardlessOfUnit() {
        let document = makeDocument(wordCount: 750, characterCount: 4000, sentenceCount: 15)
        for unit in WritingGoal.Unit.allCases {
            let goal = WritingGoal(unit: unit, target: 0, mode: .atLeast)
            XCTAssertEqual(SheetCell.progress(for: document, goal: goal), 0, "unit \(unit)")
        }
    }
}

//
//  ReaderTitleOverflowTests.swift
//  LunaTests
//


import LunaReaderUI
import UIKit
import XCTest

final class ReaderTitleOverflowTests: XCTestCase {
    private let font = UIFont.systemFont(ofSize: 30, weight: .bold)
    private let width: CGFloat = 280

    /// Comfortably past three lines of 30-point type at 280 points.
    private let longTitle = """
        The Rise and Fall and Rise Again of the Very Long Newspaper Headline That \
        Refuses to End Before the Fourth Line of Its Own Card
        """

    func testTitleThatFitsHasNoOverflow() {
        let split = ReaderTitleOverflow.split(
            "A Short Headline", font: font, width: width, maxLines: 3)
        XCTAssertEqual(split.head, "A Short Headline")
        XCTAssertNil(split.overflow)
    }

    func testLongTitleOverflowsWithoutLosingAWord() throws {
        let split = ReaderTitleOverflow.split(longTitle, font: font, width: width, maxLines: 3)
        let overflow = try XCTUnwrap(split.overflow)
        XCTAssertFalse(split.head.isEmpty)
        // The break lands on a wrap point, so the two parts rejoin into exactly
        // the original headline — nothing is dropped and no word is cut.
        XCTAssertEqual(split.head + " " + overflow, longTitle)
    }

    func testHeadFitsInsideTheLineCap() {
        let split = ReaderTitleOverflow.split(longTitle, font: font, width: width, maxLines: 3)
        let label = UILabel()
        label.font = font
        label.numberOfLines = 0
        label.text = split.head
        let height = label.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)).height
        XCTAssertLessThanOrEqual(height, font.lineHeight * 3 + 1)
    }

    func testMoreLinesAllowedMeansLessOverflow() {
        let three = ReaderTitleOverflow.split(longTitle, font: font, width: width, maxLines: 3)
        let five = ReaderTitleOverflow.split(longTitle, font: font, width: width, maxLines: 5)
        XCTAssertGreaterThan(five.head.count, three.head.count)
    }

    func testDegenerateInputsAreReturnedWhole() {
        XCTAssertNil(
            ReaderTitleOverflow.split(longTitle, font: font, width: 0, maxLines: 3).overflow)
        XCTAssertNil(
            ReaderTitleOverflow.split(longTitle, font: font, width: width, maxLines: 0).overflow)
        XCTAssertEqual(
            ReaderTitleOverflow.split("", font: font, width: width, maxLines: 3).head, "")
    }

    func testOverflowReadsAsAContinuation() {
        XCTAssertEqual(
            ReaderTitleOverflow.displayString(forOverflow: "of Its Own Card"),
            "…of Its Own Card")
    }
}

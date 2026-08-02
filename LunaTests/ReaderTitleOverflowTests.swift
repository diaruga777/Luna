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

    // MARK: - Shrink to fit

    /// One line past the cap at nominal size, and inside it two notches down —
    /// the case the shrink exists for.
    private let slightlyLongTitle = "The Rise and Fall and Rise Again of a Long Newspaper Story"

    func testTitleThatAlreadyFitsIsNotShrunk() {
        let fit = ReaderTitleOverflow.fit(
            "A Short Headline", font: font, width: width, maxLines: 3)
        XCTAssertEqual(fit.font.pointSize, font.pointSize)
        XCTAssertEqual(fit.head, "A Short Headline")
        XCTAssertNil(fit.overflow)
    }

    func testTitleJustPastTheCapShrinksInsteadOfOverflowing() {
        XCTAssertNotNil(
            ReaderTitleOverflow.split(
                slightlyLongTitle, font: font, width: width, maxLines: 3
            ).overflow,
            "precondition: this title overruns the cap at nominal size")

        let fit = ReaderTitleOverflow.fit(
            slightlyLongTitle, font: font, width: width, maxLines: 3)
        XCTAssertNil(fit.overflow)
        XCTAssertEqual(fit.head, slightlyLongTitle)
        XCTAssertLessThan(fit.font.pointSize, font.pointSize)
        XCTAssertGreaterThanOrEqual(fit.font.pointSize, font.pointSize * 0.8)
    }

    func testShrunkTitleActuallyFitsTheLineCap() {
        let fit = ReaderTitleOverflow.fit(
            slightlyLongTitle, font: font, width: width, maxLines: 3)
        let label = UILabel()
        label.font = fit.font
        label.numberOfLines = 0
        label.text = fit.head
        let height = label.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)).height
        XCTAssertLessThanOrEqual(height, fit.font.lineHeight * 3 + 1)
    }

    func testTitleIsShrunkNoFurtherThanItHasTo() {
        let fit = ReaderTitleOverflow.fit(
            slightlyLongTitle, font: font, width: width, maxLines: 3)
        // One step larger than the size chosen must not fit, or the sweep
        // overshot and the headline is smaller than it needed to be.
        let larger = fit.font.withSize(fit.font.pointSize * 1.03)
        XCTAssertNotNil(
            ReaderTitleOverflow.split(
                slightlyLongTitle, font: larger, width: width, maxLines: 3
            ).overflow)
    }

    func testTitleTooLongForTheFloorOverflowsAtTheSmallestType() {
        let fit = ReaderTitleOverflow.fit(longTitle, font: font, width: width, maxLines: 3)
        let overflow = try? XCTUnwrap(fit.overflow)
        XCTAssertNotNil(overflow)
        // The floor is 80% of nominal, and the split is taken there so the head
        // carries as much of the headline as the cap can hold.
        XCTAssertEqual(fit.font.pointSize, font.pointSize * 0.8, accuracy: 0.01)
        XCTAssertEqual(fit.head + " " + (overflow ?? ""), longTitle)
        // Shrinking first means strictly more of the headline lands in the head
        // than the plain nominal-size split managed.
        let unshrunk = ReaderTitleOverflow.split(
            longTitle, font: font, width: width, maxLines: 3)
        XCTAssertGreaterThan(fit.head.count, unshrunk.head.count)
    }

    func testMinimumScaleBoundsTheShrink() {
        let noShrink = ReaderTitleOverflow.fit(
            slightlyLongTitle, font: font, width: width, maxLines: 3, minimumScale: 1)
        XCTAssertEqual(noShrink.font.pointSize, font.pointSize)
        XCTAssertNotNil(noShrink.overflow)
    }

    func testDegenerateInputsAreFittedWhole() {
        for fit in [
            ReaderTitleOverflow.fit(longTitle, font: font, width: 0, maxLines: 3),
            ReaderTitleOverflow.fit(longTitle, font: font, width: width, maxLines: 0),
        ] {
            XCTAssertNil(fit.overflow)
            XCTAssertEqual(fit.font.pointSize, font.pointSize)
        }
        XCTAssertEqual(
            ReaderTitleOverflow.fit("", font: font, width: width, maxLines: 3).head, "")
    }

    func testOverflowReadsAsAContinuation() {
        XCTAssertEqual(
            ReaderTitleOverflow.displayString(forOverflow: "of Its Own Card"),
            "…of Its Own Card")
    }
}

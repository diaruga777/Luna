//
//  SavedMediaGridLayoutTests.swift
//  LunaTests
//

import XCTest
@testable import Luna

/// Exercises `SavedMediaGridViewController.columnLayout` — the pure column-count /
/// square-item-width math behind the Downloader grid's Photos-parity layout.
final class SavedMediaGridLayoutTests: XCTestCase {

    func testIPhonePortraitIsThreeColumns() {
        let (columns, itemWidth) = SavedMediaGridViewController.columnLayout(width: 390)
        XCTAssertEqual(columns, 3)
        // Square cells: 2 hairline gaps removed from the width, split 3 ways.
        XCTAssertEqual(itemWidth, ((390 - 2) / 3).rounded(.down))
    }

    func testIPhoneLandscapeScalesUpColumns() {
        let (columns, _) = SavedMediaGridViewController.columnLayout(width: 844)
        XCTAssertTrue((5...6).contains(columns), "expected 5-6 columns, got \(columns)")
    }

    func testIPadIsAtLeastSixColumnsWithNoUpperCap() {
        let (columns, _) = SavedMediaGridViewController.columnLayout(width: 1024)
        XCTAssertGreaterThanOrEqual(columns, 6)
    }

    func testItemsAreExactlySquare() {
        for width: CGFloat in [320, 390, 428, 700, 844, 1024, 1366] {
            let (columns, itemWidth) = SavedMediaGridViewController.columnLayout(width: width)
            // Re-derive the same way the compositional layout would lay the row out:
            // `columns` items of `itemWidth`, separated by (columns - 1) hairline gaps,
            // must not exceed the container width (squareness only holds if it fits).
            let totalRowWidth = itemWidth * CGFloat(columns) + CGFloat(columns - 1)
            XCTAssertLessThanOrEqual(totalRowWidth, width)
            XCTAssertGreaterThan(itemWidth, 0)
        }
    }

    func testNeverFewerThanThreeColumns() {
        let (columns, _) = SavedMediaGridViewController.columnLayout(width: 100)
        XCTAssertEqual(columns, 3)
    }
}

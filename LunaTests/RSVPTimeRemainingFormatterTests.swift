//
//  RSVPTimeRemainingFormatterTests.swift
//  LunaTests
//

import LunaReaderUI
import XCTest

final class RSVPTimeRemainingFormatterTests: XCTestCase {
    private let english = Locale(identifier: "en_US")

    func testUsesAbbreviatedHoursMinutesAndSeconds() {
        XCTAssertEqual(
            RSVPTimeRemainingFormatter.string(from: 3_661, locale: english),
            "1h 1m 1s")
    }

    func testRoundsUpPartialSecondsSoUnfinishedReadingNeverShowsZero() {
        XCTAssertEqual(
            RSVPTimeRemainingFormatter.string(from: 0.01, locale: english),
            "1s")
        XCTAssertEqual(
            RSVPTimeRemainingFormatter.string(from: 60.01, locale: english),
            "1m 1s")
    }

    func testZeroAndInvalidDurationsAreSafe() {
        XCTAssertEqual(RSVPTimeRemainingFormatter.string(from: 0, locale: english), "0s")
        XCTAssertEqual(
            RSVPTimeRemainingFormatter.string(from: .infinity, locale: english),
            "0s")
    }
}

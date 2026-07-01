//
//  PriceFormattingTests.swift
//  LunaTests
//

import LunaModels
import XCTest
@testable import Luna

/// Coverage for `PriceFormatting`: currency strings and the threshold description
/// shown as both a percent and an absolute alert price.
final class PriceFormattingTests: XCTestCase {

    func testCurrencyString() {
        XCTAssertEqual(PriceFormatting.string(amount: Decimal(string: "45.99")!, currency: "USD"),
                       "$45.99")
        XCTAssertEqual(PriceFormatting.string(amount: Decimal(string: "23.50")!, currency: "EUR"),
                       "€23.50")
    }

    func testThresholdDescriptionShowsPercentAndAbsolute() {
        let description = PriceFormatting.thresholdDescription(
            fraction: 0.10, initialPrice: Decimal(string: "100")!, currency: "USD")
        XCTAssertEqual(description, "10% off — alert below $90.00")
    }

    func testThresholdDescriptionRoundsPercent() {
        let description = PriceFormatting.thresholdDescription(
            fraction: 0.155, initialPrice: Decimal(string: "200")!, currency: "USD")
        XCTAssertTrue(description.hasPrefix("16% off"), description)
        XCTAssertTrue(description.contains("$169.00"), description)
    }
}

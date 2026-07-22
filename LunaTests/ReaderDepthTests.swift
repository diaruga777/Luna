//
//  ReaderDepthTests.swift
//  LunaTests
//

import LunaDesignSystem
import UIKit
import XCTest
@testable import Luna

final class ReaderDepthTests: XCTestCase {

    private let dark = UITraitCollection(userInterfaceStyle: .dark)
    private let light = UITraitCollection(userInterfaceStyle: .light)

    private func white(_ color: UIColor, _ traits: UITraitCollection) -> CGFloat {
        var w: CGFloat = -1, a: CGFloat = 0
        color.resolvedColor(with: traits).getWhite(&w, alpha: &a)
        return w
    }

    private func contrastRatio(gray: CGFloat) -> CGFloat {
        let luminance = gray <= 0.04045
            ? gray / 12.92
            : pow((gray + 0.055) / 1.055, 2.4)
        return (luminance + 0.05) / 0.05
    }

    func testLightPaletteUsesDarkestAccessibleGrayAndBlackText() {
        let background = white(LunaColors.background, light)
        XCTAssertEqual(background, 0.46, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(contrastRatio(gray: background), 4.5)
        XCTAssertEqual(white(LunaColors.primaryText, light), 0, accuracy: 0.001)
    }

    func testDarkPaletteRemainsWhiteOnBlack() {
        XCTAssertEqual(white(LunaColors.background, dark), 0, accuracy: 0.001)
        XCTAssertEqual(white(LunaColors.primaryText, dark), 1, accuracy: 0.001)
    }

    func testDarkModeGetsLighterWithDepth() {
        let levels = (0...4).map { white(ReaderDepth.backgroundColor(for: $0), dark) }
        XCTAssertEqual(levels[0], 0.0, accuracy: 0.001)
        XCTAssertEqual(levels[4], 0.20, accuracy: 0.001)
        // Strictly increasing (each nested level a touch lighter).
        for i in 1...4 { XCTAssertGreaterThan(levels[i], levels[i - 1]) }
    }

    func testLightModeUsesLighterCharcoalWithDepth() {
        let levels = (0...4).map { white(ReaderDepth.backgroundColor(for: $0), light) }
        XCTAssertEqual(levels[0], 0.46, accuracy: 0.001)
        XCTAssertEqual(levels[4], 0.66, accuracy: 0.001)
        // Nested layers stay in the charcoal family while gaining depth.
        for i in 1...4 { XCTAssertGreaterThan(levels[i], levels[i - 1]) }
    }

    func testDepthClampsAboveMax() {
        // Depth 99 clamps to level 4.
        XCTAssertEqual(
            white(ReaderDepth.backgroundColor(for: 99), dark),
            white(ReaderDepth.backgroundColor(for: 4), dark),
            accuracy: 0.001)
    }

    func testDepthClampsBelowZero() {
        XCTAssertEqual(
            white(ReaderDepth.backgroundColor(for: -5), light),
            white(ReaderDepth.backgroundColor(for: 0), light),
            accuracy: 0.001)
    }
}

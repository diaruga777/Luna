//
//  ReaderDepthTests.swift
//  LunaTests
//

import LunaDesignSystem
import UIKit
import XCTest
@testable import Luna

final class ReaderDepthTests: XCTestCase {

    // The palette keys off `LunaSkyTrait`, not `userInterfaceStyle` — the style
    // itself is pinned to `.dark` app-wide. See `LunaSky`.
    private let dark = UITraitCollection { $0.lunaSky = .night }
    private let light = UITraitCollection { $0.lunaSky = .predawn }

    private func white(_ color: UIColor, _ traits: UITraitCollection) -> CGFloat {
        var w: CGFloat = -1, a: CGFloat = 0
        color.resolvedColor(with: traits).getWhite(&w, alpha: &a)
        return w
    }

    private func components(_ color: UIColor, _ traits: UITraitCollection)
        -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b)
    }

    /// Light mode is the predawn theme: still night, one barely perceptible notch
    /// above dark mode's black, and never dark-on-light.
    func testLightPaletteIsANearBlackPredawnSky() {
        let background = white(LunaColors.background, light)
        XCTAssertEqual(background, 0.055, accuracy: 0.01)
        XCTAssertGreaterThan(background, white(LunaColors.background, dark))
        // Light text on a dark sky, exactly as in dark mode.
        XCTAssertGreaterThan(white(LunaColors.primaryText, light), 0.9)
    }

    /// The lift carries a chromatic cast, so predawn is not merely a gray.
    func testPredawnSurfaceIsTintedRatherThanNeutral() {
        for surface in [
            LunaSurfacePalette.Surface.luna, .reader, .downloader, .priceTracker,
        ] {
            let color = LunaSurfacePalette.predawnSurface(level: 0.055, for: surface)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(color.getRed(&r, green: &g, blue: &b, alpha: &a))
            // Near-black in every app: the mean channel tracks the requested level.
            XCTAssertEqual((r + g + b) / 3, 0.055, accuracy: 0.004)
            // …but never a pure gray, and never loud either.
            let spread = max(r, max(g, b)) - min(r, min(g, b))
            XCTAssertGreaterThan(spread, 0.001, "\(surface) has no cast at all")
            XCTAssertLessThan(spread, 0.06, "\(surface)'s cast is too strong")
        }
    }

    /// The central app is achromatic moonlight; the others carry their own colour.
    func testLunaSkyIsNeutralAndOtherAppsAreNot() {
        let luna = components(
            LunaSurfacePalette.predawnSurface(level: 0.055, for: .luna), light)
        XCTAssertEqual(luna.r, luna.b, accuracy: 0.012)
        let downloader = components(
            LunaSurfacePalette.predawnSurface(level: 0.055, for: .downloader), light)
        XCTAssertGreaterThan(downloader.r, downloader.b, "amber app should sit warm")
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

    func testPredawnModeGetsLighterWithDepth() {
        let levels = (0...4).map { white(ReaderDepth.backgroundColor(for: $0), light) }
        XCTAssertEqual(levels[0], 0.055, accuracy: 0.01)
        XCTAssertEqual(levels[4], 0.230, accuracy: 0.01)
        // Nested layers stay deep in the night sky while gaining depth.
        for i in 1...4 { XCTAssertGreaterThan(levels[i], levels[i - 1]) }
        // Every predawn level sits a notch above its dark-mode twin.
        for i in 0...4 {
            XCTAssertGreaterThan(
                levels[i], white(ReaderDepth.backgroundColor(for: i), dark))
        }
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

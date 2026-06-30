//
//  ReaderDepthTests.swift
//  LuneTests
//

import LuneDesignSystem
import UIKit
import XCTest
@testable import Lune

final class ReaderDepthTests: XCTestCase {

    private let dark = UITraitCollection(userInterfaceStyle: .dark)
    private let light = UITraitCollection(userInterfaceStyle: .light)

    private func white(_ color: UIColor, _ traits: UITraitCollection) -> CGFloat {
        var w: CGFloat = -1, a: CGFloat = 0
        color.resolvedColor(with: traits).getWhite(&w, alpha: &a)
        return w
    }

    func testDarkModeGetsLighterWithDepth() {
        let levels = (0...4).map { white(ReaderDepth.backgroundColor(for: $0), dark) }
        XCTAssertEqual(levels[0], 0.0, accuracy: 0.001)
        XCTAssertEqual(levels[4], 0.20, accuracy: 0.001)
        // Strictly increasing (each nested level a touch lighter).
        for i in 1...4 { XCTAssertGreaterThan(levels[i], levels[i - 1]) }
    }

    func testLightModeGetsDarkerWithDepth() {
        let levels = (0...4).map { white(ReaderDepth.backgroundColor(for: $0), light) }
        XCTAssertEqual(levels[0], 1.0, accuracy: 0.001)
        XCTAssertEqual(levels[4], 0.87, accuracy: 0.001)
        // Strictly decreasing (each nested level a touch darker).
        for i in 1...4 { XCTAssertLessThan(levels[i], levels[i - 1]) }
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

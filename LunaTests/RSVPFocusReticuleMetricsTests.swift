//
//  RSVPFocusReticuleMetricsTests.swift
//  LunaTests
//

import LunaDesignSystem
import UIKit
import XCTest

final class RSVPFocusReticuleMetricsTests: XCTestCase {

    private let capTop: CGFloat = 300
    private let capHeight: CGFloat = 28
    private let characterWidth: CGFloat = 20

    private var frame: CGRect {
        RSVPFocusReticuleMetrics.frame(
            focalX: 160, capTop: capTop, capHeight: capHeight,
            characterWidth: characterWidth)
    }

    func testTheReticuleIsCenteredOnTheFocalColumn() {
        XCTAssertEqual(frame.midX, 160, accuracy: 0.5)
    }

    /// The cue frames the glyph rather than crowding it: each hairline's inward
    /// tick has to STOP with clearance to spare, above the cap and below the
    /// baseline alike.
    func testTicksStopClearOfTheGlyphOnBothSides() {
        let tickReach = RSVPFocusReticuleMetrics.lineThickness
            + RSVPFocusReticuleMetrics.tickLength

        let topTickEnd = frame.minY + tickReach
        let bottomTickStart = frame.maxY - tickReach
        let baseline = capTop + capHeight

        XCTAssertLessThanOrEqual(
            topTickEnd, capTop - RSVPFocusReticuleMetrics.glyphClearance + 0.5)
        XCTAssertGreaterThanOrEqual(
            bottomTickStart, baseline + RSVPFocusReticuleMetrics.glyphClearance - 0.5)
        XCTAssertGreaterThan(RSVPFocusReticuleMetrics.glyphClearance, 0)
    }
}

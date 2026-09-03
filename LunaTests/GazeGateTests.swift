//
//  GazeGateTests.swift
//  LunaTests
//

import ARKit
import CoreGraphics
import XCTest
@testable import LunaGaze

final class GazeGateTests: XCTestCase {

    private let screenSize = CGSize(width: 393, height: 852)
    private let pointsPerDegree: CGFloat = 44.8

    private func makeGate() -> GazeGate {
        GazeGate(screenSize: screenSize, pointsPerDegree: pointsPerDegree)
    }

    private func onScreen() -> CGPoint { CGPoint(x: 200, y: 400) }

    func testATrackedOpenEyeOnTheScreenOpensTheGate() {
        var gate = makeGate()
        let reason = gate.update(
            faceTracked: true, blinkLeft: 0.02, blinkRight: 0.03, point: onScreen(), at: 0)
        XCTAssertEqual(reason, .ok)
        XCTAssertTrue(gate.isOpen)
    }

    func testEitherEyeClosedClosesTheGate() {
        var gate = makeGate()
        XCTAssertEqual(
            gate.update(faceTracked: true, blinkLeft: 0.5, blinkRight: 0.02, point: onScreen(), at: 0),
            .blink)
        XCTAssertEqual(
            gate.update(faceTracked: true, blinkLeft: 0.02, blinkRight: 0.5, point: onScreen(), at: 1),
            .blink)
        XCTAssertEqual(
            gate.update(faceTracked: true, blinkLeft: 0.44, blinkRight: 0.44, point: onScreen(), at: 2),
            .ok)
    }

    func testADroppedFrameIsNotAnAbsenceButARunOfThemIs() {
        var gate = makeGate()
        gate.update(faceTracked: true, blinkLeft: 0, blinkRight: 0, point: onScreen(), at: 0)
        XCTAssertEqual(
            gate.update(faceTracked: false, blinkLeft: 0, blinkRight: 0, point: nil, at: 0.2), .ok)
        XCTAssertEqual(
            gate.update(faceTracked: false, blinkLeft: 0, blinkRight: 0, point: nil, at: 0.4), .away)
    }

    func testAGateThatHasNeverSeenAFaceIsAway() {
        var gate = makeGate()
        XCTAssertEqual(
            gate.update(faceTracked: false, blinkLeft: 0, blinkRight: 0, point: nil, at: 0), .away)
    }

    func testAnEstimatePastTheSlopIsOffScreenAndOneInsideItIsNot() {
        var gate = makeGate()
        let slop = 1.5 * pointsPerDegree
        let justInside = CGPoint(x: 200, y: screenSize.height + slop - 1)
        XCTAssertEqual(
            gate.update(faceTracked: true, blinkLeft: 0, blinkRight: 0, point: justInside, at: 0), .ok)
        let justOutside = CGPoint(x: 200, y: screenSize.height + slop + 1)
        XCTAssertEqual(
            gate.update(faceTracked: true, blinkLeft: 0, blinkRight: 0, point: justOutside, at: 1),
            .offScreen)
        XCTAssertEqual(
            gate.update(faceTracked: true, blinkLeft: 0, blinkRight: 0, point: CGPoint(x: -200, y: 400), at: 2),
            .offScreen)
    }

    func testBlinkOutranksAnOffScreenEstimate() {
        var gate = makeGate()
        let reason = gate.update(
            faceTracked: true, blinkLeft: 0.9, blinkRight: 0.9,
            point: CGPoint(x: 5000, y: 5000), at: 0)
        XCTAssertEqual(reason, .blink, "a closed eye explains the wild estimate")
    }

    func testAFrameWithNoEstimateStillOpensTheGateWhenTheFaceIsThere() {
        var gate = makeGate()
        XCTAssertEqual(
            gate.update(faceTracked: true, blinkLeft: 0, blinkRight: 0, point: nil, at: 0), .ok)
    }

    func testResetForgetsThatAFaceWasEverSeen() {
        var gate = makeGate()
        gate.update(faceTracked: true, blinkLeft: 0, blinkRight: 0, point: onScreen(), at: 0)
        gate.reset()
        XCTAssertEqual(gate.reason, .away)
        XCTAssertEqual(
            gate.update(faceTracked: false, blinkLeft: 0, blinkRight: 0, point: nil, at: 0.1), .away)
    }

    func testBlinkIsReadFromBothBlendShapesAndAMissingOneCountsAsOpen() {
        let both = GazeGate.blink(from: [
            .eyeBlinkLeft: NSNumber(value: 0.8), .eyeBlinkRight: NSNumber(value: 0.1),
        ])
        XCTAssertEqual(both.left, 0.8, accuracy: 0.0001)
        XCTAssertEqual(both.right, 0.1, accuracy: 0.0001)
        let missing = GazeGate.blink(from: [:])
        XCTAssertEqual(missing.left, 0)
        XCTAssertEqual(missing.right, 0)
    }
}

//
//  GazeCalibrationFlowTests.swift
//  LunaTests
//

import CoreGraphics
import Foundation
import XCTest
@testable import LunaGaze
@testable import LunaWriterReadAlong

final class GazeCalibrationFlowTests: XCTestCase {

    private let bounds = CGRect(x: 0, y: 0, width: 390, height: 700)
    private let pointsPerDegree: CGFloat = 44.8

    /// The distortion the fit has to undo: the estimate is scaled toward the
    /// centre of the screen and pushed down and right.
    private func rawEstimate(
        for target: CGPoint, extra: CGVector = .zero, jitter: CGFloat = 0
    ) -> CGPoint {
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        return CGPoint(
            x: centre.x + (target.x - centre.x) / 1.25 + 18 + extra.dx + jitter,
            y: centre.y + (target.y - centre.y) / 1.25 - 26 + extra.dy - jitter)
    }

    private func frame(
        raw: CGPoint, at time: TimeInterval, faceTracked: Bool = true, blink: Double = 0
    ) -> CalibrationFrame {
        CalibrationFrame(
            time: time,
            raw: raw,
            eyeUnits: CGPoint(x: raw.x / bounds.width, y: raw.y / bounds.height),
            blink: blink,
            isFaceTracked: faceTracked)
    }

    /// Runs a whole calibration, one 60 Hz frame at a time, and records the
    /// stages it passed through.
    @discardableResult
    private func run(
        _ flow: GazeCalibrationFlow,
        stages: inout [GazeCalibrationStage],
        validationError: [GazeScreenQuadrant: CGVector] = [:]
    ) -> Int {
        flow.begin(at: 0)
        stages.append(flow.stage)
        var time: TimeInterval = 0
        var frames = 0
        while flow.stage != .verdict, flow.stage != .failed, time < 60 {
            if let dot = flow.dotPosition {
                var extra = CGVector.zero
                if case .validation(let index) = flow.stage {
                    let quadrant = GazeScreenQuadrant.containing(
                        flow.validationPoints[index], in: bounds.size)
                    extra = validationError[quadrant] ?? .zero
                }
                let jitter: CGFloat = frames.isMultiple(of: 2) ? 0.6 : -0.6
                flow.ingest(
                    frame(
                        raw: rawEstimate(for: dot, extra: extra, jitter: jitter), at: time))
                frames += 1
            }
            time += 1.0 / 60
            let before = flow.stage
            let after = flow.tick(at: time)
            if after != before { stages.append(after) }
        }
        return frames
    }

    // MARK: - The state machine

    func testAFullRunPassesThroughPursuitHeadTurnAndFourValidationPoints() {
        let flow = GazeCalibrationFlow(
            style: .full, bounds: bounds, pointsPerDegree: pointsPerDegree)
        XCTAssertEqual(flow.stage, .intro)

        var stages: [GazeCalibrationStage] = []
        run(flow, stages: &stages)

        XCTAssertEqual(
            stages,
            [.pursuit, .headTurn, .validation(0), .validation(1), .validation(2),
             .validation(3), .verdict])
        XCTAssertNotNil(flow.calibration)
        XCTAssertNotNil(flow.verdict)
    }

    func testAQuickTouchUpSkipsTheHeadTurnStage() {
        let flow = GazeCalibrationFlow(
            style: .quick, bounds: bounds, pointsPerDegree: pointsPerDegree)
        var stages: [GazeCalibrationStage] = []
        run(flow, stages: &stages)

        XCTAssertFalse(flow.includesHeadTurn)
        XCTAssertFalse(stages.contains(.headTurn))
        XCTAssertEqual(stages.first, .pursuit)
        XCTAssertEqual(stages.last, .verdict)
    }

    func testTheFitUndoesTheDistortionTheEstimateCarried() {
        let flow = GazeCalibrationFlow(
            style: .full, bounds: bounds, pointsPerDegree: pointsPerDegree)
        var stages: [GazeCalibrationStage] = []
        run(flow, stages: &stages)

        guard let calibration = flow.calibration, let verdict = flow.verdict else {
            return XCTFail("the sweep produced no fit")
        }
        let target = CGPoint(x: 300, y: 500)
        let corrected = calibration.point(from: rawEstimate(for: target))
        XCTAssertEqual(corrected.x, target.x, accuracy: 8)
        XCTAssertEqual(corrected.y, target.y, accuracy: 8)
        XCTAssertEqual(verdict.grade, .good)
        XCTAssertLessThan(verdict.degrees, 1.2)
    }

    func testARunWithNoUsableFramesFailsRatherThanFittingNothing() {
        let flow = GazeCalibrationFlow(
            style: .quick, bounds: bounds, pointsPerDegree: pointsPerDegree)
        flow.begin(at: 0)
        var time: TimeInterval = 0
        while flow.stage != .verdict, flow.stage != .failed, time < 30 {
            if let dot = flow.dotPosition {
                flow.ingest(
                    frame(raw: rawEstimate(for: dot), at: time, faceTracked: false))
            }
            time += 1.0 / 60
            flow.tick(at: time)
        }
        XCTAssertEqual(flow.stage, .failed)
        XCTAssertNil(flow.calibration)
    }

    func testCancellingStopsTheRunAndShowsNoDot() {
        let flow = GazeCalibrationFlow(
            style: .quick, bounds: bounds, pointsPerDegree: pointsPerDegree)
        flow.begin(at: 0)
        flow.tick(at: 1)
        XCTAssertNotNil(flow.dotPosition)

        flow.cancel()
        XCTAssertEqual(flow.stage, .failed)
        XCTAssertNil(flow.dotPosition)
    }

    // MARK: - The verdict

    func testAnEvenFitOffersNoRegionalTouchUp() {
        let flow = GazeCalibrationFlow(
            style: .full, bounds: bounds, pointsPerDegree: pointsPerDegree)
        var stages: [GazeCalibrationStage] = []
        run(flow, stages: &stages)
        XCTAssertNil(flow.touchUpQuadrant)
    }

    func testOneBadCornerOffersATouchUpOfThatCorner() {
        let flow = GazeCalibrationFlow(
            style: .full, bounds: bounds, pointsPerDegree: pointsPerDegree)
        var stages: [GazeCalibrationStage] = []
        run(
            flow, stages: &stages,
            validationError: [.bottomRight: CGVector(dx: 0, dy: 130)])

        XCTAssertEqual(flow.stage, .verdict)
        XCTAssertEqual(flow.verdict?.worstQuadrant.quadrant, .bottomRight)
        XCTAssertEqual(flow.touchUpQuadrant, .bottomRight)
    }

    func testAnEvenlyPoorFitIsNotMistakenForOneBadCorner() {
        let flow = GazeCalibrationFlow(
            style: .full, bounds: bounds, pointsPerDegree: pointsPerDegree)
        var stages: [GazeCalibrationStage] = []
        let everywhere = CGVector(dx: 0, dy: 120)
        run(
            flow, stages: &stages,
            validationError: [
                .topLeft: everywhere, .topRight: everywhere,
                .bottomLeft: everywhere, .bottomRight: everywhere,
            ])

        XCTAssertEqual(flow.verdict?.grade, .rough)
        XCTAssertNil(
            flow.touchUpQuadrant, "an evenly poor fit needs a new sweep, not a corner")
    }

    func testAFramesTimeMustClearTheSettleBeforeItValidatesAPoint() {
        let flow = GazeCalibrationFlow(
            style: .quick, bounds: bounds, pointsPerDegree: pointsPerDegree)
        var stages: [GazeCalibrationStage] = []
        run(flow, stages: &stages)
        guard let verdict = flow.verdict else { return XCTFail("no verdict") }
        // Every validation point is held for 1.5 s and only counted after
        // 600 ms, so a settle that was ignored would show as a large error.
        XCTAssertLessThan(verdict.worstQuadrant.error, 1.6 * pointsPerDegree)
    }
}

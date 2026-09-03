//
//  CalibrationSampleCollectorTests.swift
//  LunaTests
//

import CoreGraphics
import XCTest
@testable import LunaGaze

final class CalibrationSampleCollectorTests: XCTestCase {

    private let viewSize = CGSize(width: 393, height: 852)

    /// A window of the opening hold that is settled for every candidate lag, so
    /// each buffer sees exactly the frames offered.
    private let firstFrame: TimeInterval = 0.60
    private let frameCount = 20

    private func makePath() -> PursuitCalibrationPath {
        PursuitCalibrationPath.full(in: CGRect(origin: .zero, size: viewSize))
    }

    private func collect(
        _ describe: (Int) -> CalibrationFrame
    ) -> CalibrationSampleCollector {
        let collector = CalibrationSampleCollector(path: makePath(), startTime: 0)
        for index in 0..<frameCount { collector.ingest(describe(index)) }
        return collector
    }

    private func steadyFrame(_ index: Int, blink: Double = 0) -> CalibrationFrame {
        CalibrationFrame(
            time: firstFrame + Double(index) / 60,
            raw: CGPoint(x: 100 + CGFloat(index), y: 300),
            eyeUnits: CGPoint(x: 0.10, y: -0.05),
            blink: blink)
    }

    func testEveryCleanFrameBecomesOnePairPerCandidateLag() {
        let collector = collect { steadyFrame($0) }
        XCTAssertEqual(collector.offeredFrameCount, frameCount)
        XCTAssertEqual(collector.acceptedFrameCount, frameCount)
        XCTAssertEqual(collector.buffers.count, GazeAffineCalibration.lagCandidates.count)
        for buffer in collector.buffers {
            XCTAssertEqual(buffer.samples.count, frameCount, "lag \(buffer.lag)")
        }
    }

    func testBlinkingFramesAreRefused() {
        let collector = collect { index in
            steadyFrame(index, blink: index.isMultiple(of: 5) ? 0.5 : 0.1)
        }
        XCTAssertEqual(collector.acceptedFrameCount, frameCount - 4)
        XCTAssertEqual(collector.buffers[0].samples.count, frameCount - 4)
    }

    func testAFrameAtTheBlinkThresholdIsStillUsed() {
        let collector = collect { steadyFrame($0, blink: 0.3) }
        XCTAssertEqual(collector.acceptedFrameCount, frameCount)
    }

    func testAnUntrackedFrameIsRefused() {
        let collector = collect { index in
            CalibrationFrame(
                time: firstFrame + Double(index) / 60,
                raw: CGPoint(x: 100, y: 300),
                eyeUnits: CGPoint(x: 0.10, y: -0.05),
                blink: 0,
                isFaceTracked: index != 3)
        }
        XCTAssertEqual(collector.acceptedFrameCount, frameCount - 1)
    }

    func testASaccadeCostsItsOwnFrameAndTheOneItLandsOn() {
        let collector = collect { index in
            // The eye leaves the dot at frame 10 and lands at frame 11.
            let units = index >= 10
                ? CGPoint(x: 0.30, y: -0.05)
                : CGPoint(x: 0.10, y: -0.05)
            return CalibrationFrame(
                time: firstFrame + Double(index) / 60,
                raw: CGPoint(x: 100, y: 300),
                eyeUnits: units,
                blink: 0)
        }
        XCTAssertEqual(collector.acceptedFrameCount, frameCount - 2)
    }

    func testSlowPursuitIsNotMistakenForASaccade() {
        let collector = collect { index in
            CalibrationFrame(
                time: firstFrame + Double(index) / 60,
                raw: CGPoint(x: 100, y: 300),
                // 0.06 units per second — the speed pursuit actually runs at.
                eyeUnits: CGPoint(x: 0.10 + CGFloat(index) * 0.001, y: -0.05),
                blink: 0)
        }
        XCTAssertEqual(collector.acceptedFrameCount, frameCount)
    }

    func testFramesTakenBeforeTheEyeCanHaveSettledMakeNoPairs() {
        let collector = CalibrationSampleCollector(path: makePath(), startTime: 0)
        for index in 0..<10 {
            collector.ingest(CalibrationFrame(
                time: Double(index) / 60,
                raw: CGPoint(x: 100, y: 300),
                eyeUnits: CGPoint(x: 0.1, y: 0)))
        }
        XCTAssertEqual(collector.offeredFrameCount, 10)
        XCTAssertEqual(collector.acceptedFrameCount, 0)
    }

    func testResetEmptiesEveryBuffer() {
        let collector = collect { steadyFrame($0) }
        collector.reset()
        XCTAssertEqual(collector.acceptedFrameCount, 0)
        XCTAssertEqual(collector.offeredFrameCount, 0)
        XCTAssertTrue(collector.buffers.allSatisfy { $0.samples.isEmpty })
    }

    func testTooFewPairsFitNothing() {
        let collector = collect { steadyFrame($0) }
        XCTAssertNil(collector.fit(viewSize: viewSize))
    }
}

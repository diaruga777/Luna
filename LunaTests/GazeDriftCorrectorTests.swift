//
//  GazeDriftCorrectorTests.swift
//  LunaTests
//

import CoreGraphics
import XCTest
@testable import LunaGaze

final class GazeDriftCorrectorTests: XCTestCase {

    private let pointsPerDegree: CGFloat = 44.8

    private func reading(quality: Double, mode: ReadingState.Mode = .gaze, residual: CGFloat = 10)
        -> ReadingState
    {
        ReadingState(
            activeSentence: 0, readUpToWord: 2, cursorWord: 3,
            mode: mode, quality: quality, residual: residual)
    }

    private func corrector() -> GazeDriftCorrector {
        GazeDriftCorrector(pointsPerDegree: pointsPerDegree)
    }

    private let gaze = CGPoint(x: 100, y: 300)
    private let band: CGFloat = 340

    func testTheSlowCorrectionRunsOnItsOwnIntervalAndPullsTowardTheBand() {
        var corrector = corrector()
        let state = reading(quality: 0.8)
        XCTAssertNil(corrector.update(at: 0, gaze: gaze, bandCentreY: band, state: state))
        XCTAssertNil(
            corrector.update(at: 1.0, gaze: gaze, bandCentreY: band, state: state),
            "not yet a full interval")
        guard let correction = corrector.update(
            at: 1.3, gaze: gaze, bandCentreY: band, state: state)
        else { return XCTFail("no correction after the interval") }
        XCTAssertEqual(correction.gain, 0.03, accuracy: 0.0001)
        XCTAssertEqual(correction.axes, .verticalOnly)
        XCTAssertEqual(correction.error.dy, 40, accuracy: 0.0001)
        XCTAssertEqual(correction.error.dx, 0)
    }

    func testAUserScrollEarnsOneStrongerCorrectionOnceItSettles() {
        var corrector = corrector()
        let state = reading(quality: 0.8)
        _ = corrector.update(at: 0, gaze: gaze, bandCentreY: band, state: state)
        corrector.userDidScroll(at: 2.0)
        XCTAssertNotEqual(
            corrector.update(at: 2.3, gaze: gaze, bandCentreY: band, state: state)?.gain, 0.12,
            "the stronger correction must not fight a scroll still in progress")
        guard let strong = corrector.update(
            at: 2.6, gaze: gaze, bandCentreY: band, state: state)
        else { return XCTFail("no correction after the scroll settled") }
        XCTAssertEqual(strong.gain, 0.12, accuracy: 0.0001)
        // The same scroll does not earn a second strong correction.
        XCTAssertNil(corrector.update(at: 2.7, gaze: gaze, bandCentreY: band, state: state))
    }

    func testTheSlowCorrectionNeedsMoreConfidenceThanTheScrollOne() {
        var middling = reading(quality: 0.55)
        var corrector = corrector()
        _ = corrector.update(at: 0, gaze: gaze, bandCentreY: band, state: middling)
        XCTAssertNil(
            corrector.update(at: 1.3, gaze: gaze, bandCentreY: band, state: middling),
            "0.55 is below the slow correction's bar")
        corrector.userDidScroll(at: 2.0)
        XCTAssertNotNil(
            corrector.update(at: 2.6, gaze: gaze, bandCentreY: band, state: middling),
            "0.55 clears the scroll correction's bar")
        middling.quality = 0.3
        corrector.userDidScroll(at: 4.0)
        XCTAssertNil(corrector.update(at: 4.6, gaze: gaze, bandCentreY: band, state: middling))
    }

    func testAGapTooSmallToMatterOrTooLargeToTrustIsIgnored() {
        let state = reading(quality: 0.9)
        var tiny = corrector()
        _ = tiny.update(at: 0, gaze: gaze, bandCentreY: band, state: state)
        XCTAssertNil(tiny.update(
            at: 1.3, gaze: gaze, bandCentreY: gaze.y + 0.3 * pointsPerDegree, state: state))
        var huge = corrector()
        _ = huge.update(at: 0, gaze: gaze, bandCentreY: band, state: state)
        XCTAssertNil(huge.update(
            at: 1.3, gaze: gaze, bandCentreY: gaze.y + 5 * pointsPerDegree, state: state))
    }

    func testNothingIsCorrectedWhileTheModelIsRunningOnItsOwn() {
        var corrector = corrector()
        let state = reading(quality: 0.9, mode: .auto)
        _ = corrector.update(at: 0, gaze: gaze, bandCentreY: band, state: state)
        XCTAssertNil(corrector.update(at: 1.3, gaze: gaze, bandCentreY: band, state: state))
    }

    func testNothingIsCorrectedWithoutAGazeOrASentence() {
        var corrector = corrector()
        let state = reading(quality: 0.9)
        _ = corrector.update(at: 0, gaze: nil, bandCentreY: band, state: state)
        XCTAssertNil(corrector.update(at: 1.3, gaze: nil, bandCentreY: band, state: state))
        XCTAssertNil(corrector.update(at: 2.6, gaze: gaze, bandCentreY: nil, state: state))
    }

    func testACorrectionAppliedToTheCalibrationMovesTheEstimateTowardTheBand() {
        var corrector = corrector()
        var calibration = GazeAffineCalibration.identity(
            viewSize: CGSize(width: 393, height: 852), pointsPerDegree: pointsPerDegree)
        let state = reading(quality: 0.9)
        _ = corrector.update(at: 0, gaze: gaze, bandCentreY: band, state: state)
        guard let correction = corrector.update(
            at: 1.3, gaze: gaze, bandCentreY: band, state: state)
        else { return XCTFail("no correction") }
        calibration.nudge(toward: correction.error, gain: correction.gain, axes: correction.axes)
        XCTAssertEqual(calibration.point(from: gaze).y, gaze.y + 40 * 0.03, accuracy: 0.0001)
        XCTAssertEqual(calibration.point(from: gaze).x, gaze.x, accuracy: 0.0001)
    }

    func testAResidualThatWillNotComeDownAsksForAnotherSweep() {
        var corrector = corrector()
        let bad = reading(quality: 0.9, residual: 3.5 * pointsPerDegree)
        var time: TimeInterval = 0
        while time < 9.5 {
            _ = corrector.update(at: time, gaze: gaze, bandCentreY: band, state: bad)
            XCTAssertFalse(corrector.needsRecalibration, "asked too early, at \(time)")
            time += 0.5
        }
        _ = corrector.update(at: 10.5, gaze: gaze, bandCentreY: band, state: bad)
        XCTAssertTrue(corrector.needsRecalibration)
    }

    func testAResidualThatRecoversNeverAsks() {
        var corrector = corrector()
        let bad = reading(quality: 0.9, residual: 3.5 * pointsPerDegree)
        let fine = reading(quality: 0.9, residual: 20)
        var time: TimeInterval = 0
        while time < 30 {
            let state = Int(time) % 12 < 6 ? bad : fine
            _ = corrector.update(at: time, gaze: gaze, bandCentreY: band, state: state)
            time += 0.5
        }
        XCTAssertFalse(corrector.needsRecalibration)
    }

    func testAViewThatChangedSizeAlotAsksForAnotherSweep() {
        let calibration = GazeAffineCalibration.identity(
            viewSize: CGSize(width: 393, height: 852), pointsPerDegree: pointsPerDegree)
        var small = corrector()
        small.viewDidResize(to: CGSize(width: 393, height: 800), calibration: calibration)
        XCTAssertFalse(small.needsRecalibration)
        var large = corrector()
        large.viewDidResize(to: CGSize(width: 852, height: 393), calibration: calibration)
        XCTAssertTrue(large.needsRecalibration)
        large.reset()
        XCTAssertFalse(large.needsRecalibration)
    }
}

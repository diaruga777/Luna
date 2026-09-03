//
//  GazeCalibrationTests.swift
//  LunaTests
//
//  The implicit gaze calibration: warm-up median, re-anchoring, slow
//  re-centring. See claudedocs/eye-tracking.md.
//

import CoreGraphics
import LunaReaderUI
import XCTest
@testable import LunaGaze

final class GazeCalibrationTests: XCTestCase {

    func testNoOffsetUntilTheWarmupCompletes() {
        var calibration = GazeCalibration(warmupSampleCount: 5)
        calibration.beginWarmup()
        for _ in 0..<4 {
            calibration.ingest(CGVector(dx: 100, dy: -40))
            XCTAssertNil(calibration.offset)
            XCTAssertTrue(calibration.isWarmingUp)
        }
        calibration.ingest(CGVector(dx: 100, dy: -40))
        XCTAssertEqual(calibration.offset?.dx, 100)
        XCTAssertEqual(calibration.offset?.dy, -40)
        XCTAssertFalse(calibration.isWarmingUp)
    }

    func testWarmupTakesThePerAxisMedianSoAGlanceAwayIsAnOutlierNotData() {
        var calibration = GazeCalibration(warmupSampleCount: 5)
        calibration.beginWarmup()
        // Four samples reading (bias ~300pt right), one wild glance.
        for residual in [
            CGVector(dx: 298, dy: 12), CGVector(dx: 305, dy: 8),
            CGVector(dx: -900, dy: 600),  // the glance
            CGVector(dx: 300, dy: 10), CGVector(dx: 302, dy: 11),
        ] {
            calibration.ingest(residual)
        }
        XCTAssertEqual(calibration.offset?.dx ?? 0, 300, accuracy: 3)
        XCTAssertEqual(calibration.offset?.dy ?? 0, 10, accuracy: 3)
    }

    func testIngestOutsideAWarmupIsIgnored() {
        var calibration = GazeCalibration(warmupSampleCount: 2)
        calibration.ingest(CGVector(dx: 50, dy: 50))
        calibration.ingest(CGVector(dx: 50, dy: 50))
        XCTAssertNil(calibration.offset, "nothing vouched for these samples")
    }

    func testReanchoringKeepsTheOldOffsetUntilTheNewOneIsReady() {
        var calibration = GazeCalibration(warmupSampleCount: 2)
        calibration.beginWarmup()
        calibration.ingest(CGVector(dx: 100, dy: 0))
        calibration.ingest(CGVector(dx: 100, dy: 0))
        XCTAssertEqual(calibration.offset?.dx, 100)

        calibration.beginWarmup()
        XCTAssertEqual(calibration.offset?.dx, 100,
                       "no coverage gap while the new anchor collects")
        calibration.ingest(CGVector(dx: 20, dy: 0))
        XCTAssertEqual(calibration.offset?.dx, 100)
        calibration.ingest(CGVector(dx: 20, dy: 0))
        XCTAssertEqual(calibration.offset?.dx, 20)
    }

    func testInvalidateWarmupDropsPartialResidualsButKeepsCollecting() {
        var calibration = GazeCalibration(warmupSampleCount: 2)
        calibration.beginWarmup()
        calibration.ingest(CGVector(dx: 500, dy: 500))
        calibration.invalidateWarmup()  // the focal word jumped

        calibration.ingest(CGVector(dx: 10, dy: 0))
        XCTAssertNil(calibration.offset, "the stale residual must not count toward the anchor")
        calibration.ingest(CGVector(dx: 10, dy: 0))
        XCTAssertEqual(calibration.offset?.dx, 10)
    }

    func testRecentreDriftsSlowlyTowardFreshResiduals() {
        var calibration = GazeCalibration(warmupSampleCount: 1, recentreRate: 0.1)
        calibration.beginWarmup()
        calibration.ingest(CGVector(dx: 100, dy: 0))

        calibration.recentre(towards: CGVector(dx: 200, dy: 0))
        XCTAssertEqual(calibration.offset?.dx ?? 0, 110, accuracy: 0.001,
                       "one step moves a tenth of the way, not all of it")
    }

    func testRecentreBeforeEstablishmentIsANoOp() {
        var calibration = GazeCalibration(warmupSampleCount: 5)
        calibration.recentre(towards: CGVector(dx: 100, dy: 100))
        XCTAssertNil(calibration.offset)
    }

    func testCalibratedAppliesTheOffsetAndIsIdentityBeforehand() {
        var calibration = GazeCalibration(warmupSampleCount: 1)
        let point = CGPoint(x: 400, y: 300)
        XCTAssertEqual(calibration.calibrated(point), point)

        calibration.beginWarmup()
        calibration.ingest(CGVector(dx: 30, dy: -20))
        XCTAssertEqual(calibration.calibrated(point), CGPoint(x: 370, y: 320))
    }

    func testResetForgetsEverything() {
        var calibration = GazeCalibration(warmupSampleCount: 1)
        calibration.beginWarmup()
        calibration.ingest(CGVector(dx: 30, dy: -20))
        calibration.reset()
        XCTAssertNil(calibration.offset)
        XCTAssertFalse(calibration.isWarmingUp)
    }
}

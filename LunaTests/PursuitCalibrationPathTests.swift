//
//  PursuitCalibrationPathTests.swift
//  LunaTests
//

import CoreGraphics
import XCTest
@testable import LunaGaze

final class PursuitCalibrationPathTests: XCTestCase {

    private let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
    private let wide = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private func samples(of path: PursuitCalibrationPath, step: TimeInterval = 1.0 / 120)
        -> [(time: TimeInterval, sample: PursuitCalibrationPath.Sample)]
    {
        var out: [(TimeInterval, PursuitCalibrationPath.Sample)] = []
        var time: TimeInterval = 0
        while time <= path.duration {
            out.append((time, path.sample(at: time)))
            time += step
        }
        return out
    }

    func testTheDotTravelsInsideTheBoundsForEveryShape() {
        for path in [
            PursuitCalibrationPath.full(in: bounds),
            PursuitCalibrationPath.quick(in: bounds),
            PursuitCalibrationPath.region(.bottomRight, in: bounds),
            PursuitCalibrationPath.region(.topLeft, in: bounds),
        ] {
            for (time, sample) in samples(of: path) {
                XCTAssertTrue(
                    bounds.contains(sample.point),
                    "\(sample.point) left the bounds at \(time)")
            }
        }
    }

    func testTheSweepIsFinishedOnlyAtItsEnd() {
        let path = PursuitCalibrationPath.full(in: bounds)
        XCTAssertFalse(path.sample(at: 0).isDone)
        XCTAssertFalse(path.sample(at: path.duration - 0.01).isDone)
        XCTAssertTrue(path.sample(at: path.duration).isDone)
        XCTAssertTrue(path.sample(at: path.duration + 5).isDone)
        XCTAssertFalse(path.sample(at: -1).isUsable)
    }

    func testTheSpeedIsClampedAndTheEasingNeverDoublesIt() {
        let phone = PursuitCalibrationPath.full(in: bounds)
        let laptop = PursuitCalibrationPath.full(in: wide)
        for path in [phone, laptop] {
            XCTAssertTrue(
                PursuitCalibrationPath.speedBounds.contains(path.speed),
                "speed \(path.speed) outside the clamp")
        }
        // A short travel would run slower than the floor, so it is held at it;
        // a long one would run faster than the ceiling, so it is held there.
        XCTAssertEqual(phone.speed, PursuitCalibrationPath.speedBounds.lowerBound)
        XCTAssertGreaterThan(laptop.speed, phone.speed)

        var previous = phone.position(at: 0)
        var peak: CGFloat = 0
        var time: TimeInterval = 1.0 / 240
        while time <= phone.duration {
            let point = phone.position(at: time)
            let step = ((point.x - previous.x) * (point.x - previous.x)
                + (point.y - previous.y) * (point.y - previous.y)).squareRoot()
            peak = max(peak, step * 240)
            previous = point
            time += 1.0 / 240
        }
        // Smoothstep peaks at 1.5x the average speed of a move.
        XCTAssertLessThan(peak, phone.speed * 1.6)
        XCTAssertGreaterThan(peak, phone.speed)
    }

    func testTheStartHoldKeepsTheDotStillAndUnusableWhileTheEyeFindsIt() {
        let path = PursuitCalibrationPath.full(in: bounds)
        let start = path.position(at: 0)
        XCTAssertEqual(path.position(at: PursuitCalibrationPath.startHold - 0.01), start)
        XCTAssertFalse(path.sample(at: 0).isUsable)
        XCTAssertFalse(path.sample(at: PursuitCalibrationPath.settleDelay - 0.01).isUsable)
        XCTAssertTrue(path.sample(at: PursuitCalibrationPath.settleDelay + 0.01).isUsable)
        XCTAssertFalse(path.sample(at: 0).isMoving)
    }

    func testEveryDirectionChangeIsFollowedByAnUnusableSettleWindow() {
        let path = PursuitCalibrationPath.full(in: bounds)
        var wasMoving = false
        var changes = 0
        for (time, sample) in samples(of: path, step: 1.0 / 240) {
            if sample.isMoving != wasMoving {
                wasMoving = sample.isMoving
                changes += 1
                XCTAssertFalse(
                    sample.isUsable, "frames right after a direction change at \(time) must be dropped")
            }
        }
        XCTAssertGreaterThan(changes, 6, "a three-row lawnmower turns several times")
    }

    func testTheQuickSweepIsShorterThanTheFullOne() {
        let full = PursuitCalibrationPath.full(in: bounds)
        let quick = PursuitCalibrationPath.quick(in: bounds)
        let region = PursuitCalibrationPath.region(.topRight, in: bounds)
        XCTAssertLessThan(quick.duration, full.duration)
        XCTAssertLessThan(region.duration, quick.duration)
        XCTAssertEqual(quick.duration, 7, accuracy: 1.5)
    }

    func testTheValidationPointsSitInsideTheFourQuadrants() {
        let points = PursuitCalibrationPath.validationPoints(in: bounds)
        XCTAssertEqual(points.count, 4)
        XCTAssertEqual(
            Set(points.map { GazeScreenQuadrant.containing($0, in: bounds.size) }),
            Set(GazeScreenQuadrant.allCases))
        let xs = Set(points.map { ($0.x / bounds.width * 100).rounded() })
        let ys = Set(points.map { ($0.y / bounds.height * 100).rounded() })
        XCTAssertEqual(xs, [22, 78])
        XCTAssertEqual(ys, [24, 76])
    }

    func testARegionSweepCirclesItsOwnQuadrant() {
        for quadrant in GazeScreenQuadrant.allCases {
            let path = PursuitCalibrationPath.region(quadrant, in: bounds)
            let centre = path.position(at: 0)
            XCTAssertEqual(
                GazeScreenQuadrant.containing(centre, in: bounds.size), quadrant)
            let visited = samples(of: path).map(\.sample.point)
            let spread = visited.map(\.x).max()! - visited.map(\.x).min()!
            XCTAssertGreaterThan(spread, 0, "the dot must actually move")
        }
    }

    func testABoundsWithAnOriginShiftsTheWholeSweep() {
        let offset = CGRect(x: 100, y: 200, width: 393, height: 852)
        let path = PursuitCalibrationPath.full(in: offset)
        for (_, sample) in samples(of: path) {
            XCTAssertTrue(offset.contains(sample.point))
        }
        XCTAssertEqual(
            PursuitCalibrationPath.validationPoints(in: offset).first?.x ?? 0,
            100 + 0.22 * 393, accuracy: 0.001)
    }
}

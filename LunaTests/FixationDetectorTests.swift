//
//  FixationDetectorTests.swift
//  LunaTests
//

import CoreGraphics
import XCTest
@testable import LunaGaze

final class FixationDetectorTests: XCTestCase {

    private let pointsPerDegree: CGFloat = 44.8

    func testAHeldGazeBecomesAFixationAtTheMeanOfItsSamples() {
        let detector = FixationDetector(pointsPerDegree: pointsPerDegree)
        var fixation: Fixation?
        for frame in 0..<10 {
            let jitter = CGFloat(frame % 3)
            fixation = detector.ingest(CGPoint(x: 100 + jitter, y: 200), at: Double(frame) / 60)
        }
        guard let held = fixation else { return XCTFail("no fixation after ten still frames") }
        XCTAssertEqual(held.point.y, 200, accuracy: 0.001)
        XCTAssertEqual(held.point.x, 101, accuracy: 1.5)
        XCTAssertGreaterThanOrEqual(held.duration, detector.minimumDuration)
    }

    func testAWindowShorterThanTheMinimumDurationIsNotYetAFixation() {
        let detector = FixationDetector(pointsPerDegree: pointsPerDegree)
        XCTAssertNil(detector.ingest(CGPoint(x: 100, y: 200), at: 0))
        XCTAssertNil(detector.ingest(CGPoint(x: 100, y: 200), at: 1.0 / 60))
        XCTAssertNil(detector.ingest(CGPoint(x: 100, y: 200), at: 2.0 / 60))
        XCTAssertNil(detector.ingest(CGPoint(x: 100, y: 200), at: 3.0 / 60))
        XCTAssertNotNil(detector.ingest(CGPoint(x: 100, y: 200), at: 5.0 / 60))
    }

    func testASweepingGazeNeverSettlesIntoAFixation() {
        let detector = FixationDetector(pointsPerDegree: pointsPerDegree)
        var last: Fixation?
        for frame in 0..<20 {
            last = detector.ingest(CGPoint(x: 100 + CGFloat(frame) * 30, y: 200), at: Double(frame) / 60)
        }
        XCTAssertNil(last)
    }

    func testASaccadeEndsTheFixationAndTheNextOneStartsWhereTheEyeLanded() {
        let detector = FixationDetector(pointsPerDegree: pointsPerDegree)
        for frame in 0..<10 { detector.ingest(CGPoint(x: 100, y: 200), at: Double(frame) / 60) }
        XCTAssertEqual(detector.fixation?.point.x, 100)
        for frame in 10..<24 { detector.ingest(CGPoint(x: 600, y: 500), at: Double(frame) / 60) }
        let landed = detector.fixation
        XCTAssertEqual(landed?.point.x ?? 0, 600, accuracy: 0.001)
        XCTAssertEqual(landed?.point.y ?? 0, 500, accuracy: 0.001)
    }

    func testASilenceLongerThanTheMaximumGapDropsTheFixation() {
        let detector = FixationDetector(pointsPerDegree: pointsPerDegree)
        for frame in 0..<10 { detector.ingest(CGPoint(x: 100, y: 200), at: Double(frame) / 60) }
        XCTAssertNotNil(detector.fixation)
        detector.ingest(CGPoint(x: 100, y: 200), at: 3.0)
        XCTAssertNil(detector.fixation, "the window resets after a gap, so nothing is held")
    }

    func testAJitteryGazeInsideTheDispersionThresholdStaysOneFixation() {
        let detector = FixationDetector(pointsPerDegree: pointsPerDegree)
        var random = SimRandom(seed: 3)
        var frames = 0
        var held = 0
        for frame in 0..<120 {
            let point = CGPoint(x: 300 + random.gaussian(10), y: 400 + random.gaussian(10))
            if detector.ingest(point, at: Double(frame) / 60) != nil { held += 1 }
            frames += 1
        }
        XCTAssertGreaterThan(Double(held) / Double(frames), 0.9)
        XCTAssertEqual(detector.fixation?.point.y ?? 0, 400, accuracy: 20)
    }

    func testNonFiniteSamplesAreIgnored() {
        let detector = FixationDetector(pointsPerDegree: pointsPerDegree)
        for frame in 0..<10 { detector.ingest(CGPoint(x: 100, y: 200), at: Double(frame) / 60) }
        let before = detector.fixation
        let after = detector.ingest(CGPoint(x: CGFloat.nan, y: 200), at: 11.0 / 60)
        XCTAssertEqual(before?.point, after?.point)
    }
}

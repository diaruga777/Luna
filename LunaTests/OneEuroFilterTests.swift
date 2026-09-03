//
//  OneEuroFilterTests.swift
//  LunaTests
//

import CoreGraphics
import XCTest
@testable import LunaGaze

final class OneEuroFilterTests: XCTestCase {

    private func standardDeviation(_ values: [CGFloat]) -> CGFloat {
        let mean = values.reduce(0, +) / CGFloat(values.count)
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / CGFloat(values.count)
        return variance.squareRoot()
    }

    func testAStillGazeComesOutSteadier() {
        var filter = OneEuroFilter()
        var random = SimRandom(seed: 7)
        var raw: [CGPoint] = []
        var filtered: [CGPoint] = []
        for frame in 0..<200 {
            let point = CGPoint(x: 200 + random.gaussian(12), y: 400 + random.gaussian(12))
            raw.append(point)
            filtered.append(filter.filter(point, at: Double(frame) / 60))
        }
        let before = standardDeviation(raw.map(\.x))
        let after = standardDeviation(filtered.suffix(150).map(\.x))
        XCTAssertGreaterThan(before, after * 2, "jitter should be at least halved")
    }

    func testFastMotionIsTrackedFarMoreCloselyThanAFixedCutoffWould() {
        var adaptive = OneEuroFilter()
        var fixed = OneEuroFilter(
            configuration: .init(minCutoff: 1.0, beta: 0, derivativeCutoff: 1.0))
        var adaptiveLag: CGFloat = 0
        var fixedLag: CGFloat = 0
        for frame in 0..<40 {
            let time = Double(frame) / 60
            let point = CGPoint(x: 100 + CGFloat(time) * 900, y: 0)
            let a = adaptive.filter(point, at: time)
            let f = fixed.filter(point, at: time)
            adaptiveLag = point.x - a.x
            fixedLag = point.x - f.x
        }
        XCTAssertLessThan(adaptiveLag, 20)
        XCTAssertGreaterThan(fixedLag, adaptiveLag * 5, "the speed term is what removes the lag")
    }

    func testAGapLongerThanTheResetWindowStartsAFreshStream() {
        var filter = OneEuroFilter()
        _ = filter.filter(CGPoint(x: 10, y: 10), at: 0)
        _ = filter.filter(CGPoint(x: 12, y: 12), at: 1.0 / 60)
        let afterGap = filter.filter(CGPoint(x: 500, y: 500), at: 1.0)
        XCTAssertEqual(afterGap.x, 500, accuracy: 0.001)
        XCTAssertEqual(afterGap.y, 500, accuracy: 0.001)
    }

    func testTheFirstSampleIsPassedThroughUnchanged() {
        var filter = OneEuroFilter()
        let first = filter.filter(CGPoint(x: 42, y: -17), at: 0)
        XCTAssertEqual(first.x, 42, accuracy: 0.001)
        XCTAssertEqual(first.y, -17, accuracy: 0.001)
        XCTAssertEqual(filter.currentValue?.x, 42)
    }

    func testResetForgetsTheStream() {
        var filter = OneEuroFilter()
        for frame in 0..<30 { _ = filter.filter(CGPoint(x: 100, y: 100), at: Double(frame) / 60) }
        filter.reset()
        XCTAssertNil(filter.currentValue)
        let next = filter.filter(CGPoint(x: 700, y: 700), at: 1)
        XCTAssertEqual(next.x, 700, accuracy: 0.001)
    }
}

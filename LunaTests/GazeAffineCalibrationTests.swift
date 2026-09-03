//
//  GazeAffineCalibrationTests.swift
//  LunaTests
//

import CoreGraphics
import UIKit
import XCTest
@testable import LunaGaze

final class GazeAffineCalibrationTests: XCTestCase {

    private let viewSize = CGSize(width: 393, height: 852)
    private let pointsPerDegree: CGFloat = 44.8

    /// The distortion the estimator is assumed to carry: a gain per axis, a
    /// little shear, and a bias.
    private let truth = CGAffineTransform(a: 1.12, b: 0.03, c: -0.05, d: 0.91, tx: 25, ty: -40)

    private func options() -> GazeAffineCalibration.FitOptions {
        var options = GazeAffineCalibration.FitOptions()
        options.pointsPerDegree = pointsPerDegree
        return options
    }

    /// Raw estimates spread over the display, with `truth` applied backwards:
    /// the calibration has to invert what the estimator did.
    private func samples(count: Int, noise: Double, seed: Int64 = 11) -> [CalibrationSample] {
        var random = SimRandom(seed: seed)
        return (0..<count).map { _ in
            let target = CGPoint(
                x: random.unit() * Double(viewSize.width),
                y: random.unit() * Double(viewSize.height))
            // The raw estimate is what the distorted eye reports for `target`.
            let inverse = target.applying(truth.inverted())
            let raw = CGPoint(
                x: inverse.x + random.gaussian(noise),
                y: inverse.y + random.gaussian(noise))
            return CalibrationSample(raw: raw, target: target)
        }
    }

    func testTheFitRecoversAKnownAffineAndBiasThroughGaussianNoise() {
        guard let fitted = GazeAffineCalibration.fit(
            samples: samples(count: 400, noise: 6), viewSize: viewSize, options: options())
        else { return XCTFail("no fit") }

        for probe in [CGPoint(x: 40, y: 60), CGPoint(x: 350, y: 800), CGPoint(x: 200, y: 430)] {
            let raw = probe.applying(truth.inverted())
            let recovered = fitted.point(from: raw)
            XCTAssertEqual(recovered.x, probe.x, accuracy: 6)
            XCTAssertEqual(recovered.y, probe.y, accuracy: 6)
        }
        XCTAssertLessThan(fitted.fitRMS, 12)
        XCTAssertEqual(fitted.sampleCount, 400)
    }

    func testTheFitIsFarBetterThanNoCalibrationAtAll() {
        let held = samples(count: 60, noise: 6, seed: 99)
        guard let fitted = GazeAffineCalibration.fit(
            samples: samples(count: 400, noise: 6), viewSize: viewSize, options: options())
        else { return XCTFail("no fit") }
        let identity = GazeAffineCalibration.identity(
            viewSize: viewSize, pointsPerDegree: pointsPerDegree)
        XCTAssertLessThan(
            fitted.rootMeanSquareError(over: held),
            identity.rootMeanSquareError(over: held) / 4)
    }

    func testWildOutliersAreDroppedAndDoNotMoveTheAnswer() {
        var clean = samples(count: 400, noise: 6)
        let cleanFit = GazeAffineCalibration.fit(
            samples: clean, viewSize: viewSize, options: options())
        var random = SimRandom(seed: 5)
        // One frame in ten is the eye somewhere else entirely.
        for index in stride(from: 0, to: clean.count, by: 10) {
            clean[index] = CalibrationSample(
                raw: CGPoint(x: random.unit() * 400, y: random.unit() * 900),
                target: clean[index].target)
        }
        guard let robust = GazeAffineCalibration.fit(
            samples: clean, viewSize: viewSize, options: options()),
            let cleanFit
        else { return XCTFail("no fit") }

        XCTAssertLessThan(robust.keptSampleCount, robust.sampleCount)
        let probe = CGPoint(x: 200, y: 430)
        let raw = probe.applying(truth.inverted())
        XCTAssertEqual(robust.point(from: raw).x, cleanFit.point(from: raw).x, accuracy: 14)
        XCTAssertEqual(robust.point(from: raw).y, cleanFit.point(from: raw).y, accuracy: 14)
    }

    func testTheLagSearchFindsTheLagTheEyeActuallyHad() {
        let path = PursuitCalibrationPath.full(in: CGRect(origin: .zero, size: viewSize))
        let collector = CalibrationSampleCollector(path: path, startTime: 0)
        let trueLag: TimeInterval = 0.18
        var random = SimRandom(seed: 21)
        var time: TimeInterval = 0
        while time <= path.duration {
            // The frame reports where the eye was `trueLag` ago.
            let dot = path.sample(at: time - trueLag)
            let raw = dot.point.applying(truth.inverted())
            collector.ingest(CalibrationFrame(
                time: time,
                raw: CGPoint(x: raw.x + random.gaussian(4), y: raw.y + random.gaussian(4)),
                eyeUnits: CGPoint(x: dot.point.x / 4000, y: dot.point.y / 4000)))
            time += 1.0 / 60
        }
        guard let fitted = collector.fit(viewSize: viewSize, options: options()) else {
            return XCTFail("no fit")
        }
        XCTAssertEqual(fitted.lag, trueLag, accuracy: 0.001)
    }

    // MARK: - Validation

    /// Held-out samples whose estimate is wrong by a fixed vector per quadrant.
    private func validation(errors: [GazeScreenQuadrant: CGVector]) -> [CalibrationSample] {
        var out: [CalibrationSample] = []
        for point in PursuitCalibrationPath.validationPoints(
            in: CGRect(origin: .zero, size: viewSize))
        {
            let quadrant = GazeScreenQuadrant.containing(point, in: viewSize)
            let error = errors[quadrant] ?? .zero
            for _ in 0..<10 {
                out.append(CalibrationSample(
                    raw: CGPoint(x: point.x - error.dx, y: point.y - error.dy), target: point))
            }
        }
        return out
    }

    func testValidationGradesTheFitByVisualAngle() {
        let identity = GazeAffineCalibration.identity(
            viewSize: viewSize, pointsPerDegree: pointsPerDegree)
        func grade(offset: CGFloat) -> CalibrationVerdict? {
            identity.validate(samples: validation(
                errors: Dictionary(uniqueKeysWithValues: GazeScreenQuadrant.allCases.map {
                    ($0, CGVector(dx: 0, dy: offset))
                })))
        }
        XCTAssertEqual(grade(offset: 0.8 * pointsPerDegree)?.grade, .good)
        XCTAssertEqual(grade(offset: 1.8 * pointsPerDegree)?.grade, .usable)
        XCTAssertEqual(grade(offset: 3.0 * pointsPerDegree)?.grade, .rough)
        let measured = grade(offset: 1.8 * pointsPerDegree)
        XCTAssertEqual(measured?.degrees ?? 0, 1.8, accuracy: 0.02)
        XCTAssertEqual(measured?.meanError ?? 0, 1.8 * pointsPerDegree, accuracy: 0.5)
    }

    func testValidationNamesTheQuadrantThatFittedWorst() {
        let identity = GazeAffineCalibration.identity(
            viewSize: viewSize, pointsPerDegree: pointsPerDegree)
        let verdict = identity.validate(samples: validation(errors: [
            .topLeft: CGVector(dx: 10, dy: 0),
            .topRight: CGVector(dx: 12, dy: 0),
            .bottomLeft: CGVector(dx: 90, dy: 0),
            .bottomRight: CGVector(dx: 8, dy: 0),
        ]))
        XCTAssertEqual(verdict?.worstQuadrant.quadrant, .bottomLeft)
        XCTAssertEqual(verdict?.worstQuadrant.error ?? 0, 90, accuracy: 0.5)
    }

    func testValidationOfNothingIsNil() {
        let identity = GazeAffineCalibration.identity(
            viewSize: viewSize, pointsPerDegree: pointsPerDegree)
        XCTAssertNil(identity.validate(samples: []))
    }

    func testRecordingAValidationKeepsIt() {
        var identity = GazeAffineCalibration.identity(
            viewSize: viewSize, pointsPerDegree: pointsPerDegree)
        XCTAssertNil(identity.verdict)
        identity.recordValidation(samples: validation(
            errors: [.topLeft: CGVector(dx: 20, dy: 0)]))
        XCTAssertEqual(identity.verdict?.grade, .good)
    }

    // MARK: - Nudging

    func testTheOnlineNudgeMovesTheBiasByItsGain() {
        var calibration = GazeAffineCalibration.identity(
            viewSize: viewSize, pointsPerDegree: pointsPerDegree)
        calibration.nudge(toward: CGVector(dx: 100, dy: -50), gain: 0.1)
        XCTAssertEqual(calibration.offset.dx, 10, accuracy: 0.001)
        XCTAssertEqual(calibration.offset.dy, -5, accuracy: 0.001)
        XCTAssertEqual(calibration.point(from: CGPoint(x: 200, y: 400)).x, 210, accuracy: 0.001)
    }

    func testAVerticalOnlyNudgeLeavesTheHorizontalBiasAlone() {
        var calibration = GazeAffineCalibration.identity(
            viewSize: viewSize, pointsPerDegree: pointsPerDegree)
        calibration.nudge(toward: CGVector(dx: 100, dy: 100), gain: 0.5, axes: .verticalOnly)
        XCTAssertEqual(calibration.offset.dx, 0)
        XCTAssertEqual(calibration.offset.dy, 50, accuracy: 0.001)
    }

    func testTheNudgeIsClampedSoAWrongFitCannotBeHiddenByIt() {
        var calibration = GazeAffineCalibration.identity(
            viewSize: viewSize, pointsPerDegree: pointsPerDegree)
        for _ in 0..<200 { calibration.nudge(toward: CGVector(dx: 400, dy: -400), gain: 0.5) }
        XCTAssertEqual(calibration.offset.dx, GazeAffineCalibration.maximumOffset)
        XCTAssertEqual(calibration.offset.dy, -GazeAffineCalibration.maximumOffset)
        calibration.resetOffset()
        XCTAssertEqual(calibration.offset.dx, 0)
    }

    // MARK: - Refusals and persistence

    func testAFitIsRefusedWhenThereAreTooFewSamples() {
        XCTAssertNil(GazeAffineCalibration.fit(
            samples: samples(count: 12, noise: 3), viewSize: viewSize, options: options()))
        XCTAssertNil(GazeAffineCalibration.fit(
            samples: samples(count: 400, noise: 3), viewSize: .zero, options: options()))
    }

    func testViewSizeDriftMeasuresRelativeChangeOnBothAxes() {
        let calibration = GazeAffineCalibration.identity(
            viewSize: viewSize, pointsPerDegree: pointsPerDegree)
        XCTAssertEqual(calibration.viewSizeDrift(from: viewSize), 0, accuracy: 0.0001)
        let halfHeight = CGSize(width: viewSize.width, height: viewSize.height / 2)
        XCTAssertEqual(calibration.viewSizeDrift(from: halfHeight), 0.5, accuracy: 0.0001)
    }

    func testACalibrationSurvivesAJSONRoundTrip() throws {
        guard var fitted = GazeAffineCalibration.fit(
            samples: samples(count: 400, noise: 6), viewSize: viewSize, options: options())
        else { return XCTFail("no fit") }
        fitted.nudge(toward: CGVector(dx: 60, dy: 20), gain: 0.5)
        fitted.recordValidation(samples: validation(errors: [.topLeft: CGVector(dx: 20, dy: 0)]))
        let data = try JSONEncoder().encode(fitted)
        let decoded = try JSONDecoder().decode(GazeAffineCalibration.self, from: data)
        XCTAssertEqual(decoded, fitted)
        let probe = CGPoint(x: 180, y: 500)
        XCTAssertEqual(decoded.point(from: probe).x, fitted.point(from: probe).x, accuracy: 0.0001)
    }

    func testTheStoreKeepsOneCalibrationPerOrientation() throws {
        let suite = "GazeAffineCalibrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GazeCalibrationStore(defaults: defaults)

        var portrait = GazeAffineCalibration.identity(
            viewSize: viewSize, pointsPerDegree: pointsPerDegree)
        portrait.nudge(toward: CGVector(dx: 100, dy: 0), gain: 1)
        var landscape = GazeAffineCalibration.identity(
            viewSize: CGSize(width: 852, height: 393), pointsPerDegree: pointsPerDegree)
        landscape.nudge(toward: CGVector(dx: 0, dy: 70), gain: 1)

        XCTAssertNil(store.calibration(for: .portrait))
        store.save(portrait, for: .portrait)
        store.save(landscape, for: .landscapeRight)

        XCTAssertEqual(store.calibration(for: .portrait)?.offset.dx, 100)
        XCTAssertEqual(store.calibration(for: .landscapeRight)?.offset.dy, 70)
        XCTAssertNil(store.calibration(for: .landscapeLeft))

        store.remove(for: .portrait)
        XCTAssertNil(store.calibration(for: .portrait))
        XCTAssertNotNil(store.calibration(for: .landscapeRight))
        store.removeAll()
        XCTAssertNil(store.calibration(for: .landscapeRight))
    }
}

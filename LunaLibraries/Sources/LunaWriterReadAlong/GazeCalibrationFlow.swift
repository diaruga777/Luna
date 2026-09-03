//
//  GazeCalibrationFlow.swift
//  LunaWriterReadAlong
//

import CoreGraphics
import Foundation
import LunaGaze

/// Which calibration is being run.
public enum GazeCalibrationStyle: Equatable {
    /// The full sweep, about 25 seconds with the head-turn stage.
    case full
    /// One S-curve, about 8 seconds.
    case quick
    /// A loop around one quadrant that fitted worst.
    case region(GazeScreenQuadrant)
}

/// Where a calibration run has got to.
public enum GazeCalibrationStage: Equatable {
    /// Waiting for the user to begin.
    case intro
    /// Following the moving dot.
    case pursuit
    /// Head turning, eyes on the centre dot.
    case headTurn
    /// One held-out point, by index.
    case validation(Int)
    /// Fitted and validated.
    case verdict
    /// Too few usable frames to fit at all.
    case failed
}

/// The calibration screen's state machine, with no UIKit in it.
///
/// Nothing here reads a clock: the screen supplies the time, so a whole run
/// replays in a test in microseconds. The head-turn stage is fitted TOGETHER
/// with the sweep — its frames all name the centre dot, which is what teaches
/// the fit that the estimate must not swing with the head.
public final class GazeCalibrationFlow {

    /// How long the head-turn stage lasts.
    public static let headTurnDuration: TimeInterval = 7
    /// How long each validation point is held.
    public static let validationHold: TimeInterval = 1.5
    /// How long a validation point settles before its frames count.
    public static let validationSettle: TimeInterval = 0.6
    /// Eye speed above which a frame is a saccade, in screen-normalised units
    /// per second. `CalibrationSampleCollector`'s own default is stated in
    /// iris units, which `GazeTracking` does not report.
    public static let saccadeVelocity: Double = 3.0
    /// Worst-quadrant error worth a regional touch-up, in degrees.
    public static let touchUpDegrees: CGFloat = 1.6
    /// Worst-quadrant error worth a touch-up, as a multiple of the mean.
    public static let touchUpMultiple: CGFloat = 1.6

    public let style: GazeCalibrationStyle
    public let bounds: CGRect
    public let pointsPerDegree: CGFloat
    public let path: PursuitCalibrationPath
    public let validationPoints: [CGPoint]

    public private(set) var stage: GazeCalibrationStage = .intro
    /// Where the dot is drawn, or nil when no dot is shown.
    public private(set) var dotPosition: CGPoint?
    public private(set) var calibration: GazeAffineCalibration?
    public private(set) var verdict: CalibrationVerdict?
    /// Frames the sweep accepted, for the "hold still" hint.
    public var acceptedFrameCount: Int { collector.acceptedFrameCount }

    private let collector: CalibrationSampleCollector
    private var headTurnSamples: [CalibrationSample] = []
    private var validationSamples: [CalibrationSample] = []
    private var stageStart: TimeInterval = 0
    private var startTime: TimeInterval = 0

    public init(
        style: GazeCalibrationStyle,
        bounds: CGRect,
        pointsPerDegree: CGFloat,
        startTime: TimeInterval = 0
    ) {
        self.style = style
        self.bounds = bounds
        self.pointsPerDegree = pointsPerDegree
        switch style {
        case .full: self.path = PursuitCalibrationPath.full(in: bounds)
        case .quick: self.path = PursuitCalibrationPath.quick(in: bounds)
        case .region(let quadrant): self.path = PursuitCalibrationPath.region(quadrant, in: bounds)
        }
        self.validationPoints = PursuitCalibrationPath.validationPoints(in: bounds)
        self.startTime = startTime
        self.collector = CalibrationSampleCollector(
            path: path,
            startTime: startTime,
            saccadeVelocity: GazeCalibrationFlow.saccadeVelocity)
    }

    /// Only the full sweep asks for a head turn; a touch-up is too short to
    /// spend seven seconds on one.
    public var includesHeadTurn: Bool { style == .full }

    /// Where the centre dot of the head-turn stage sits.
    public var headTurnPoint: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    // MARK: - Driving

    /// Leaves the intro and starts the sweep.
    public func begin(at time: TimeInterval) {
        guard stage == .intro else { return }
        startTime = time
        collector.reset()
        enter(.pursuit, at: time)
    }

    /// Advances the run to `time` and returns the stage it is in afterwards.
    @discardableResult
    public func tick(at time: TimeInterval) -> GazeCalibrationStage {
        switch stage {
        case .intro, .verdict, .failed:
            break
        case .pursuit:
            let sample = path.sample(at: time - startTime)
            dotPosition = sample.point
            if sample.isDone {
                enter(includesHeadTurn ? .headTurn : .validation(0), at: time)
            }
        case .headTurn:
            dotPosition = headTurnPoint
            if time - stageStart >= Self.headTurnDuration {
                enter(.validation(0), at: time)
            }
        case .validation(let index):
            dotPosition = validationPoints[index]
            if time - stageStart >= Self.validationHold {
                let next = index + 1
                if next < validationPoints.count {
                    enter(.validation(next), at: time)
                } else {
                    finish()
                }
            }
        }
        return stage
    }

    /// Offers one camera frame to whichever stage is collecting.
    public func ingest(_ frame: CalibrationFrame) {
        switch stage {
        case .pursuit:
            collector.ingest(frame)
        case .headTurn:
            guard frame.isFaceTracked, frame.blink <= collector.blinkMaximum else { return }
            headTurnSamples.append(
                CalibrationSample(raw: frame.raw, target: headTurnPoint, time: frame.time))
        case .validation(let index):
            guard frame.isFaceTracked, frame.blink <= collector.blinkMaximum else { return }
            guard frame.time - stageStart >= Self.validationSettle else { return }
            validationSamples.append(
                CalibrationSample(
                    raw: frame.raw, target: validationPoints[index], time: frame.time))
        default:
            break
        }
    }

    /// Abandons the run.
    public func cancel() {
        stage = .failed
        dotPosition = nil
    }

    // MARK: - Fitting

    private func enter(_ next: GazeCalibrationStage, at time: TimeInterval) {
        stage = next
        stageStart = time
        if case .validation(let index) = next { dotPosition = validationPoints[index] }
        if next == .headTurn { dotPosition = headTurnPoint }
        if next == .pursuit { dotPosition = path.position(at: 0) }
    }

    /// Fits the sweep and the head turn together, then scores the held-out
    /// points.
    private func finish() {
        dotPosition = nil
        var buffers = collector.buffers
        if !headTurnSamples.isEmpty {
            buffers = buffers.map { (lag: $0.lag, samples: $0.samples + headTurnSamples) }
        }
        var options = GazeAffineCalibration.FitOptions()
        options.pointsPerDegree = pointsPerDegree
        guard var fitted = GazeAffineCalibration.fit(
            byLag: buffers, viewSize: bounds.size, options: options)
        else {
            stage = .failed
            return
        }
        verdict = fitted.recordValidation(samples: validationSamples)
        calibration = fitted
        stage = .verdict
    }

    /// The quadrant worth a touch-up, or nil when the fit is even.
    ///
    /// An uneven fit is worth a 6-second regional loop; an evenly poor one is
    /// worth a whole new sweep, so the two answers must not be confused.
    public var touchUpQuadrant: GazeScreenQuadrant? {
        guard let verdict else { return nil }
        let limit = max(
            Self.touchUpDegrees * pointsPerDegree,
            Self.touchUpMultiple * verdict.meanError)
        guard verdict.worstQuadrant.error > limit else { return nil }
        return verdict.worstQuadrant.quadrant
    }

    /// The seconds the run takes, for the copy that offers it.
    public var estimatedDuration: TimeInterval {
        let validation = Self.validationHold * Double(validationPoints.count)
        return path.duration + (includesHeadTurn ? Self.headTurnDuration : 0) + validation
    }
}

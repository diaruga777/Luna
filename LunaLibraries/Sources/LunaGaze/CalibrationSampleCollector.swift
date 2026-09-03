//
//  CalibrationSampleCollector.swift
//  LunaGaze
//

import CoreGraphics
import Foundation

/// One camera frame offered to a calibration sweep.
public struct CalibrationFrame: Equatable {
    /// When the frame was captured, on the same clock the sweep started on.
    public let time: TimeInterval
    /// The uncalibrated screen estimate, in points.
    public let raw: CGPoint
    /// Eye-in-head direction, in dimensionless units. Only its rate of change
    /// is used, to tell a pursuit from a saccade.
    public let eyeUnits: CGPoint
    /// Blink, taken as the worse of the two eyes.
    public let blink: Double
    /// Whether a face was tracked in this frame.
    public let isFaceTracked: Bool

    public init(
        time: TimeInterval, raw: CGPoint, eyeUnits: CGPoint,
        blink: Double = 0, isFaceTracked: Bool = true
    ) {
        self.time = time
        self.raw = raw
        self.eyeUnits = eyeUnits
        self.blink = blink
        self.isFaceTracked = isFaceTracked
    }
}

/// Pairs camera frames with where the calibration dot was when they were taken.
///
/// The pairing is the whole difficulty: the dot's position is known exactly,
/// but the frame that saw it is late by an unknown lag, and the eye is late
/// again. So one buffer is filled per candidate lag and the fit decides which
/// buffer was right — a search over six numbers rather than a guess at one.
///
/// Two kinds of frame are refused outright. A blinking frame has no iris to
/// estimate from. A saccade means the eye left the dot, so neither that frame
/// nor the one that lands after it says anything about where the dot was.
public final class CalibrationSampleCollector {

    /// Blink above which a frame is dropped.
    public let blinkMaximum: Double
    /// Eye speed, in units per second, above which a frame is a saccade.
    /// Smooth pursuit runs near 0.06; a saccade is well past 1.
    public let saccadeVelocity: Double

    private let path: PursuitCalibrationPath
    /// When the sweep this collector is pairing frames against actually
    /// began, on the frames' own clock. Settable rather than fixed at
    /// construction: a caller that builds the collector before it knows the
    /// real start time (`GazeCalibrationFlow.begin(at:)`, which constructs
    /// the flow — and this collector — before the run is asked to start)
    /// must update it once that time is known, or `sample(at:)` pairs every
    /// frame against a sweep that never started when it thinks it did.
    public var startTime: TimeInterval
    private let lags: [TimeInterval]
    private var buffered: [[CalibrationSample]]

    private var previous: (time: TimeInterval, units: CGPoint)?
    private var skipNextFrame = false

    /// Frames that survived the filters.
    public private(set) var acceptedFrameCount = 0
    /// Frames offered in total.
    public private(set) var offeredFrameCount = 0

    public init(
        path: PursuitCalibrationPath,
        startTime: TimeInterval,
        lags: [TimeInterval] = GazeAffineCalibration.lagCandidates,
        blinkMaximum: Double = 0.3,
        saccadeVelocity: Double = 0.3
    ) {
        self.path = path
        self.startTime = startTime
        self.lags = lags
        self.blinkMaximum = blinkMaximum
        self.saccadeVelocity = saccadeVelocity
        self.buffered = Array(repeating: [], count: lags.count)
    }

    public func reset() {
        buffered = Array(repeating: [], count: lags.count)
        previous = nil
        skipNextFrame = false
        acceptedFrameCount = 0
        offeredFrameCount = 0
    }

    /// Offers one frame. Returns true when it became a training pair.
    @discardableResult
    public func ingest(_ frame: CalibrationFrame) -> Bool {
        offeredFrameCount += 1
        guard frame.isFaceTracked, frame.blink <= blinkMaximum else {
            previous = nil
            return false
        }
        if let previous {
            let interval = max(1e-3, frame.time - previous.time)
            let dx = Double(frame.eyeUnits.x - previous.units.x)
            let dy = Double(frame.eyeUnits.y - previous.units.y)
            let velocity = (dx * dx + dy * dy).squareRoot() / interval
            if velocity > saccadeVelocity {
                self.previous = (frame.time, frame.eyeUnits)
                skipNextFrame = true
                return false
            }
            if skipNextFrame {
                skipNextFrame = false
                self.previous = (frame.time, frame.eyeUnits)
                return false
            }
        }
        previous = (frame.time, frame.eyeUnits)

        var used = false
        for (index, lag) in lags.enumerated() {
            let dot = path.sample(at: frame.time - startTime - lag)
            guard dot.isUsable else { continue }
            buffered[index].append(
                CalibrationSample(raw: frame.raw, target: dot.point, time: frame.time))
            used = true
        }
        if used { acceptedFrameCount += 1 }
        return used
    }

    /// One buffer per candidate lag, in the order the lags were given.
    public var buffers: [(lag: TimeInterval, samples: [CalibrationSample])] {
        lags.enumerated().map { (lag: $0.element, samples: buffered[$0.offset]) }
    }

    /// Fits every buffer and keeps the lag that explains the sweep best.
    public func fit(
        viewSize: CGSize, options: GazeAffineCalibration.FitOptions = .init()
    ) -> GazeAffineCalibration? {
        GazeAffineCalibration.fit(byLag: buffers, viewSize: viewSize, options: options)
    }
}

//
//  OneEuroFilter.swift
//  LunaGaze
//

import CoreGraphics
import Foundation

/// One-euro filter (Casiez et al. 2012) over a stream of gaze points.
///
/// A fixed low-pass has to choose between jitter while the eye is still and lag
/// while it moves. This one adapts: the cutoff rises with the estimated speed,
/// so a fixation is smoothed hard and a saccade is barely touched.
public struct OneEuroFilter {

    public struct Configuration: Equatable {
        /// Cutoff, in Hz, applied when the signal is not moving.
        public var minCutoff: Double
        /// How much the cutoff rises per unit of speed.
        public var beta: Double
        /// Cutoff, in Hz, of the speed estimate itself.
        public var derivativeCutoff: Double
        /// A gap this long means a new stream, not a slow one.
        public var resetGap: TimeInterval
        /// Interval assumed for the first sample, before a rate is known.
        public var assumedInterval: TimeInterval

        public init(
            minCutoff: Double = 1.0,
            beta: Double = 0.007,
            derivativeCutoff: Double = 1.0,
            resetGap: TimeInterval = 0.4,
            assumedInterval: TimeInterval = 1.0 / 30
        ) {
            self.minCutoff = minCutoff
            self.beta = beta
            self.derivativeCutoff = derivativeCutoff
            self.resetGap = resetGap
            self.assumedInterval = assumedInterval
        }
    }

    public private(set) var configuration: Configuration

    private var value: (x: Double?, y: Double?) = (nil, nil)
    private var speed: (x: Double?, y: Double?) = (nil, nil)
    private var lastTime: TimeInterval?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Forgets the stream. The next sample passes through unchanged.
    public mutating func reset() {
        value = (nil, nil)
        speed = (nil, nil)
        lastTime = nil
    }

    /// The most recent output, or nil before the first sample.
    public var currentValue: CGPoint? {
        guard let x = value.x, let y = value.y else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// Filters one sample. `time` is in seconds and must not go backwards.
    public mutating func filter(_ point: CGPoint, at time: TimeInterval) -> CGPoint {
        var interval = configuration.assumedInterval
        if let lastTime {
            if time - lastTime > configuration.resetGap {
                reset()
            } else {
                interval = max(1e-3, time - lastTime)
            }
        }
        lastTime = time

        let derivativeAlpha = Self.alpha(cutoff: configuration.derivativeCutoff, interval: interval)
        let x = step(
            Double(point.x), previous: &value.x, speed: &speed.x,
            interval: interval, derivativeAlpha: derivativeAlpha)
        let y = step(
            Double(point.y), previous: &value.y, speed: &speed.y,
            interval: interval, derivativeAlpha: derivativeAlpha)
        return CGPoint(x: x, y: y)
    }

    private func step(
        _ sample: Double, previous: inout Double?, speed: inout Double?,
        interval: TimeInterval, derivativeAlpha: Double
    ) -> Double {
        let rate = previous.map { (sample - $0) / interval } ?? 0
        let smoothedRate = speed.map { $0 + derivativeAlpha * (rate - $0) } ?? rate
        speed = smoothedRate
        let cutoff = configuration.minCutoff + configuration.beta * abs(smoothedRate)
        let alpha = Self.alpha(cutoff: cutoff, interval: interval)
        let filtered = previous.map { $0 + alpha * (sample - $0) } ?? sample
        previous = filtered
        return filtered
    }

    static func alpha(cutoff: Double, interval: TimeInterval) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / interval)
    }
}

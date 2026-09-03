//
//  FixationDetector.swift
//  LunaGaze
//

import CoreGraphics
import Foundation

/// A held gaze: the mean of a compact window of samples.
public struct Fixation: Equatable {
    /// Mean of the samples in the window, in the caller's coordinate space.
    public let point: CGPoint
    /// How long the window has been held, in seconds.
    public let duration: TimeInterval
    /// Time of the window's oldest sample.
    public let startTime: TimeInterval
    /// Time of the window's newest sample.
    public let time: TimeInterval

    public init(point: CGPoint, duration: TimeInterval, startTime: TimeInterval, time: TimeInterval) {
        self.point = point
        self.duration = duration
        self.startTime = startTime
        self.time = time
    }
}

/// Streaming I-DT fixation filter.
///
/// Reading is a chain of fixations joined by saccades, and only the fixations
/// carry information about where the reader is. A window of recent samples is
/// kept compact by dropping its oldest members until the spread of x plus the
/// spread of y falls under the dispersion threshold; once the surviving window
/// is old enough, its mean is the fixation.
public final class FixationDetector {

    /// Sum of the x spread and the y spread a window may have, in points.
    public let dispersion: CGFloat
    /// How long a window must be held before it counts as a fixation.
    public let minimumDuration: TimeInterval
    /// A gap this long resets the window and drops the fixation.
    public let maximumGap: TimeInterval
    /// Oldest sample a window may keep, however compact it is.
    public let windowLimit: TimeInterval

    /// The fixation being held, or nil.
    public private(set) var fixation: Fixation?

    private struct Sample {
        let time: TimeInterval
        let point: CGPoint
    }

    private var window: [Sample] = []
    private var lastTime: TimeInterval?

    public init(
        dispersion: CGFloat,
        minimumDuration: TimeInterval = 0.070,
        maximumGap: TimeInterval = 0.220,
        windowLimit: TimeInterval = 0.9
    ) {
        self.dispersion = dispersion
        self.minimumDuration = minimumDuration
        self.maximumGap = maximumGap
        self.windowLimit = windowLimit
    }

    /// Thresholds in degrees of visual angle: dispersion 1.3°.
    public convenience init(
        pointsPerDegree: CGFloat,
        dispersionDegrees: CGFloat = 1.3,
        minimumDuration: TimeInterval = 0.070,
        maximumGap: TimeInterval = 0.220
    ) {
        self.init(
            dispersion: dispersionDegrees * pointsPerDegree,
            minimumDuration: minimumDuration,
            maximumGap: maximumGap)
    }

    public func reset() {
        window.removeAll()
        fixation = nil
    }

    /// Feeds one sample and returns the fixation held afterwards, if any.
    @discardableResult
    public func ingest(_ point: CGPoint, at time: TimeInterval) -> Fixation? {
        guard point.x.isFinite, point.y.isFinite else { return fixation }
        if let lastTime, time - lastTime > maximumGap { reset() }
        lastTime = time
        window.append(Sample(time: time, point: point))

        while window.count > 2, spread() > dispersion { window.removeFirst() }
        while window.count > 2, time - window[0].time > windowLimit { window.removeFirst() }

        let duration = window.isEmpty ? 0 : time - window[0].time
        if duration >= minimumDuration, window.count >= 3 {
            var sum = CGPoint.zero
            for sample in window {
                sum.x += sample.point.x
                sum.y += sample.point.y
            }
            let count = CGFloat(window.count)
            fixation = Fixation(
                point: CGPoint(x: sum.x / count, y: sum.y / count),
                duration: duration,
                startTime: window[0].time,
                time: time)
        } else if let held = fixation, time - held.time > maximumGap {
            fixation = nil
        }
        return fixation
    }

    private func spread() -> CGFloat {
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for sample in window {
            minX = min(minX, sample.point.x)
            maxX = max(maxX, sample.point.x)
            minY = min(minY, sample.point.y)
            maxY = max(maxY, sample.point.y)
        }
        return (maxX - minX) + (maxY - minY)
    }
}

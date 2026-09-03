//
//  PursuitCalibrationPath.swift
//  LunaGaze
//

import CoreGraphics
import Foundation

/// The moving target a calibration sweep asks the reader to follow.
///
/// A grid of dots to stare at gives a handful of pairs and asks for patience.
/// Smooth pursuit gives one pair per camera frame, because a target that
/// travels slowly enough is tracked by the eye continuously. The whole design
/// follows from that: hold at the start so the eye finds the dot, pause at each
/// corner so a direction change does not poison the pairs around it, ease into
/// and out of every move so velocity stays continuous, and cap the speed so a
/// mis-estimated lag costs points rather than centimetres.
public struct PursuitCalibrationPath: Equatable {

    /// Time after any direction change during which pairs are discarded. The
    /// eye needs about this long to catch up with a catch-up saccade.
    public static let settleDelay: TimeInterval = 0.300
    /// Pause held at each corner.
    public static let cornerPause: TimeInterval = 0.420
    /// Pause held at the very first point.
    public static let startHold: TimeInterval = 0.900
    /// Slowest and fastest the dot may travel, in points per second.
    public static let speedBounds: ClosedRange<CGFloat> = 250...600

    /// The dot at one instant.
    public struct Sample: Equatable {
        /// Where the dot is.
        public let point: CGPoint
        /// Whether a frame taken now is a usable training pair.
        public let isUsable: Bool
        /// Whether the dot is travelling rather than held.
        public let isMoving: Bool
        /// Whether the sweep has finished.
        public let isDone: Bool

        public init(point: CGPoint, isUsable: Bool, isMoving: Bool, isDone: Bool) {
            self.point = point
            self.isUsable = isUsable
            self.isMoving = isMoving
            self.isDone = isDone
        }
    }

    private enum Segment: Equatable {
        case hold(start: TimeInterval, end: TimeInterval, point: CGPoint)
        case move(start: TimeInterval, end: TimeInterval, from: CGPoint, to: CGPoint)

        var start: TimeInterval {
            switch self {
            case .hold(let start, _, _): return start
            case .move(let start, _, _, _): return start
            }
        }

        var end: TimeInterval {
            switch self {
            case .hold(_, let end, _): return end
            case .move(_, let end, _, _): return end
            }
        }
    }

    private let segments: [Segment]

    /// How long the whole sweep takes.
    public let duration: TimeInterval
    /// The travel speed the sweep settled on, in points per second.
    public let speed: CGFloat

    // MARK: - Shapes

    /// The full sweep: three rows of a rounded lawnmower, ending at the centre.
    public static func full(in bounds: CGRect) -> PursuitCalibrationPath {
        let inset = margin(of: bounds)
        let left = bounds.minX + inset
        let right = bounds.maxX - inset
        let rows = [bounds.minY + inset, bounds.midY, bounds.maxY - inset]
        var waypoints: [(CGPoint, TimeInterval)] = []
        for (index, y) in rows.enumerated() {
            let (a, b) = index.isMultiple(of: 2) ? (left, right) : (right, left)
            waypoints.append((CGPoint(x: a, y: y), index == 0 ? startHold : cornerPause))
            waypoints.append((CGPoint(x: b, y: y), cornerPause))
        }
        waypoints.append((CGPoint(x: bounds.midX, y: bounds.midY), 0.700))
        return PursuitCalibrationPath(waypoints: waypoints, targetDuration: 16)
    }

    /// A touch-up: one S across the page, about seven seconds.
    public static func quick(in bounds: CGRect) -> PursuitCalibrationPath {
        let inset = margin(of: bounds)
        let left = bounds.minX + inset
        let right = bounds.maxX - inset
        let waypoints: [(CGPoint, TimeInterval)] = [
            (CGPoint(x: left, y: bounds.minY + inset + 0.1 * bounds.height), startHold),
            (CGPoint(x: right, y: bounds.minY + 0.4 * bounds.height), cornerPause),
            (CGPoint(x: left, y: bounds.minY + 0.7 * bounds.height), cornerPause),
            (CGPoint(x: bounds.midX, y: bounds.midY), 0.600),
        ]
        return PursuitCalibrationPath(waypoints: waypoints, targetDuration: 7)
    }

    /// A small loop around one quadrant, for fixing the corner that fitted worst.
    public static func region(
        _ quadrant: GazeScreenQuadrant, in bounds: CGRect
    ) -> PursuitCalibrationPath {
        let unit = quadrant.unitCentre
        let centre = CGPoint(
            x: bounds.minX + unit.x * bounds.width,
            y: bounds.minY + unit.y * bounds.height)
        let radius = min(0.13 * bounds.width, 0.16 * bounds.height)
        let inset = margin(of: bounds)
        func clamp(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: min(max(point.x, bounds.minX + inset), bounds.maxX - inset),
                y: min(max(point.y, bounds.minY + inset), bounds.maxY - inset))
        }
        let waypoints: [(CGPoint, TimeInterval)] = [
            (centre, startHold),
            (clamp(CGPoint(x: centre.x - radius, y: centre.y - radius * 0.7)), cornerPause),
            (clamp(CGPoint(x: centre.x + radius, y: centre.y - radius * 0.7)), cornerPause),
            (clamp(CGPoint(x: centre.x + radius, y: centre.y + radius * 0.7)), cornerPause),
            (clamp(CGPoint(x: centre.x - radius, y: centre.y + radius * 0.7)), cornerPause),
            (centre, 0.600),
        ]
        return PursuitCalibrationPath(waypoints: waypoints, targetDuration: 6)
    }

    /// The four held-out points a fit is validated on.
    public static func validationPoints(in bounds: CGRect) -> [CGPoint] {
        GazeScreenQuadrant.allCases.map { quadrant in
            CGPoint(
                x: bounds.minX + quadrant.unitCentre.x * bounds.width,
                y: bounds.minY + quadrant.unitCentre.y * bounds.height)
        }
    }

    private static func margin(of bounds: CGRect) -> CGFloat {
        max(24, min(0.05 * bounds.width, 0.05 * bounds.height))
    }

    // MARK: - Building

    init(waypoints: [(CGPoint, TimeInterval)], targetDuration: TimeInterval) {
        var travel: CGFloat = 0
        for index in 1..<max(waypoints.count, 1) {
            travel += Self.distance(waypoints[index - 1].0, waypoints[index].0)
        }
        let paused = waypoints.reduce(TimeInterval(0)) { $0 + $1.1 }
        let moving = max(1, targetDuration - paused)
        let raw = travel / CGFloat(moving)
        let speed = min(max(raw, Self.speedBounds.lowerBound), Self.speedBounds.upperBound)

        var segments: [Segment] = []
        var clock: TimeInterval = 0
        for (index, waypoint) in waypoints.enumerated() {
            segments.append(.hold(start: clock, end: clock + waypoint.1, point: waypoint.0))
            clock += waypoint.1
            guard index + 1 < waypoints.count else { continue }
            let next = waypoints[index + 1].0
            let span = TimeInterval(Self.distance(waypoint.0, next) / speed)
            segments.append(.move(start: clock, end: clock + span, from: waypoint.0, to: next))
            clock += span
        }
        self.segments = segments
        self.duration = clock
        self.speed = speed
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: - Sampling

    /// Where the dot is, and whether now is a usable moment, at `time` seconds
    /// after the sweep started.
    public func sample(at time: TimeInterval) -> Sample {
        guard let first = segments.first, let last = segments.last else {
            return Sample(point: .zero, isUsable: false, isMoving: false, isDone: true)
        }
        if time < 0 {
            return Sample(point: Self.point(of: first, at: 0), isUsable: false, isMoving: false, isDone: false)
        }
        if time >= duration {
            return Sample(
                point: Self.point(of: last, at: last.end - last.start),
                isUsable: false, isMoving: false, isDone: true)
        }
        let segment = segments.first { time >= $0.start && time < $0.end } ?? first
        let since = time - segment.start
        switch segment {
        case .hold(_, _, let point):
            return Sample(
                point: point, isUsable: since >= Self.settleDelay, isMoving: false, isDone: false)
        case .move(let start, let end, let from, let to):
            let progress = Self.ease(min(max((time - start) / (end - start), 0), 1))
            let point = CGPoint(
                x: from.x + (to.x - from.x) * CGFloat(progress),
                y: from.y + (to.y - from.y) * CGFloat(progress))
            return Sample(
                point: point, isUsable: since >= Self.settleDelay, isMoving: true, isDone: false)
        }
    }

    /// Where the dot is at `time` seconds after the sweep started.
    public func position(at time: TimeInterval) -> CGPoint {
        sample(at: time).point
    }

    private static func point(of segment: Segment, at offset: TimeInterval) -> CGPoint {
        switch segment {
        case .hold(_, _, let point):
            return point
        case .move(let start, let end, let from, let to):
            let progress = ease(min(max(offset / max(end - start, 1e-6), 0), 1))
            return CGPoint(
                x: from.x + (to.x - from.x) * CGFloat(progress),
                y: from.y + (to.y - from.y) * CGFloat(progress))
        }
    }

    /// Smoothstep. Velocity reaches zero at both ends of a move, which is what
    /// keeps the eye locked on instead of overshooting into a saccade.
    private static func ease(_ u: TimeInterval) -> TimeInterval {
        u * u * (3 - 2 * u)
    }
}

//
//  GazeAttentionPolicy.swift
//  LunaReaderUI
//

import CoreGraphics
import Foundation

/// How long the reader may look somewhere before RSVP pauses, as a function of
/// how far from the focal word they looked.
///
/// The shape is deliberately gentle near the word and sharp far from it: a
/// glance at the progress percentage a few lines down is the sort of thing a
/// speed reader does mid-sentence and shouldn't be punished for, whereas eyes
/// leaving the phone means the next words are simply not being read. Between
/// the two the tolerance interpolates linearly, so the delay really does
/// "depend on the distance the gaze travels".
public struct GazeAttentionPolicy: Equatable {

    /// Gaze inside this radius of the focal word counts as reading. Generous on
    /// purpose: gaze estimates from a front-facing camera are good to several
    /// centimetres at arm's length, not to the letter, and RSVP's surrounding
    /// context lanes are legitimately part of the reading surface. A false
    /// pause is much more disruptive than a delayed pause.
    public var focusRadius: CGFloat
    /// The extra distance beyond `focusRadius` over which tolerance falls from
    /// `nearTolerance` to `farTolerance`. Roughly the height of a phone, so
    /// looking at the far corner of the screen already earns the short fuse.
    public var falloffDistance: CGFloat
    /// Dwell allowed just outside `focusRadius`.
    public var nearTolerance: TimeInterval
    /// Dwell allowed at `focusRadius + falloffDistance` and beyond — including
    /// a confidently off-screen gaze.
    public var farTolerance: TimeInterval

    public init(
        focusRadius: CGFloat = 240,
        falloffDistance: CGFloat = 420,
        nearTolerance: TimeInterval = 1.8,
        farTolerance: TimeInterval = 0.7
    ) {
        self.focusRadius = focusRadius
        self.falloffDistance = falloffDistance
        self.nearTolerance = nearTolerance
        self.farTolerance = farTolerance
    }

    /// The tolerance for a gaze `distance` points from the focal word, or
    /// `.infinity` when the gaze is still on the word (nothing to time).
    public func tolerance(forDistance distance: CGFloat) -> TimeInterval {
        guard distance > focusRadius else { return .infinity }
        guard falloffDistance > 0 else { return farTolerance }
        let travelled = min(1, Double((distance - focusRadius) / falloffDistance))
        return nearTolerance + (farTolerance - nearTolerance) * travelled
    }

    /// The tolerance for a whole sample. Off-screen skips the distance curve
    /// entirely and takes the shortest fuse. A lost face is not a gaze sample;
    /// the coordinator marks tracking unavailable and never passes it here.
    public func tolerance(for sample: GazeSample, focus: CGPoint) -> TimeInterval {
        switch sample {
        case .point(let point):
            return tolerance(forDistance: hypot(point.x - focus.x, point.y - focus.y))
        case .offScreen:
            return farTolerance
        case .faceLost:
            return .infinity
        }
    }
}

/// Accumulates "time spent looking away, weighted by how far away" and reports
/// when it has been long enough to pause.
///
/// It integrates rather than timing a single excursion, so a gaze that drifts
/// outward — 300pt away for a moment, then off-screen — spends its allowance at
/// the rate each instant deserves instead of being judged by wherever it
/// happened to be when a fixed timer expired. Any sample back on the word
/// resets the allowance in full.
public struct GazeAttentionMonitor {

    public var policy: GazeAttentionPolicy

    /// Fraction of the allowance spent, 0…1. Exposed for tests and for the
    /// controller's "is the reader currently looking away" question.
    public private(set) var awayProgress: Double = 0
    /// Whether the most recent sample was away from the focal word at all.
    public private(set) var isAway = false

    private var lastTimestamp: TimeInterval?

    /// Longest gap between samples that still reads as one continuous
    /// excursion. Anything longer is a discontinuity — a suspended app, a
    /// pre-empted camera — and starts the excursion over rather than being
    /// counted or clamped: clamping to any value at or above `farTolerance`
    /// would trip the threshold the instant the session resumed.
    private static let maximumSampleGap: TimeInterval = 0.5

    public init(policy: GazeAttentionPolicy = GazeAttentionPolicy()) {
        self.policy = policy
    }

    /// Forgets the time spent so far — called whenever playback starts, the
    /// focal word jumps (scrub/skip), or tracking restarts. Deliberately leaves
    /// `isAway` alone: it reports where the reader is looking NOW, and a
    /// gaze-triggered pause resets the allowance without the reader's eyes
    /// having moved back.
    public mutating func resetAllowance() {
        awayProgress = 0
        lastTimestamp = nil
    }

    /// Forgets the excursion entirely, including where the reader was last
    /// seen looking. For when tracking stops and the readings go stale.
    public mutating func clear() {
        resetAllowance()
        isAway = false
    }

    /// Feeds one gaze estimate. Returns true exactly once per excursion, on the
    /// sample that exhausts the allowance — the caller pauses and the allowance
    /// resets.
    @discardableResult
    public mutating func update(
        sample: GazeSample, focus: CGPoint, at timestamp: TimeInterval
    ) -> Bool {
        let gap = lastTimestamp.map { timestamp - $0 }
        lastTimestamp = timestamp
        var elapsed: TimeInterval = 0
        if let gap, gap > 0 {
            if gap > Self.maximumSampleGap {
                awayProgress = 0
            } else {
                elapsed = gap
            }
        }

        let tolerance = policy.tolerance(for: sample, focus: focus)
        guard tolerance.isFinite else {
            awayProgress = 0
            isAway = false
            return false
        }
        isAway = true
        guard tolerance > 0 else {
            awayProgress = 0
            return true
        }
        awayProgress += elapsed / tolerance
        guard awayProgress >= 1 else { return false }
        awayProgress = 0
        return true
    }
}

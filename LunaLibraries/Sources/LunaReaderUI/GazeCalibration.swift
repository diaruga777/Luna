//
//  GazeCalibration.swift
//  LunaReaderUI
//

import CoreGraphics
import Foundation

/// Learns and removes the gaze estimator's systematic bias.
///
/// ARKit's `lookAtPoint` carries a per-user, per-posture offset — commonly
/// several degrees, worst vertically — that absolute screen-point gaze cannot
/// escape without calibration. RSVP is uniquely placed to calibrate
/// implicitly: while playback runs the reader is, by definition, looking at
/// the focal word, and the moment playback starts is the strongest anchor of
/// all (the eyes just left the play button). So every playback start opens a
/// short WARM-UP during which the residual (raw gaze point minus focal point)
/// is collected; the per-axis MEDIAN of those residuals becomes the offset
/// subtracted from every later sample. Median, not mean: a glance away during
/// warm-up is an outlier to survive, not data to average in.
///
/// The offset then drifts with the reader rather than going stale: any sample
/// that lands within the focus radius AFTER calibration re-centres the offset
/// by a small fraction per frame (`recentreRate`), tracking slow posture
/// changes without ever chasing a genuine look-away (samples beyond the
/// radius never re-centre).
///
/// The trade-off is stated plainly: warm-up trusts playback as ground truth.
/// A reader who starts playback and immediately looks away for the whole
/// warm-up anchors the offset to the wrong place until the next playback
/// start re-anchors it. That failure is transient and rare — the alternative,
/// trusting ARKit's absolute accuracy, paused every reader every time.
public struct GazeCalibration {

    /// The learned bias, subtracted from raw samples. `nil` until the first
    /// warm-up completes — before that there is no baseline to judge against.
    public private(set) var offset: CGVector?

    /// True while residuals are being collected toward a (re-)anchor.
    public private(set) var isWarmingUp = false

    /// Samples a warm-up collects before anchoring. At the camera's ~60fps
    /// this is well under a second — short enough to finish before even the
    /// far tolerance could fire on an uncalibrated bias.
    public let warmupSampleCount: Int

    /// Fraction of the distance to a fresh in-radius residual the offset moves
    /// per sample. 0.01/frame ≈ a couple of seconds' time constant at 60fps:
    /// fast enough to follow a settling posture, far too slow to follow a
    /// glance.
    public let recentreRate: CGFloat

    private var residuals: [CGVector] = []

    public init(warmupSampleCount: Int = 45, recentreRate: CGFloat = 0.01) {
        self.warmupSampleCount = warmupSampleCount
        self.recentreRate = recentreRate
    }

    /// Opens (or reopens) a warm-up. An established offset stays in force
    /// while the new anchor collects, so re-anchoring never leaves a gap in
    /// coverage.
    public mutating func beginWarmup() {
        residuals.removeAll()
        isWarmingUp = true
    }

    /// Drops a warm-up's partial residuals but keeps collecting — for when the
    /// focal point jumps mid-warm-up and the residuals gathered so far were
    /// measured against a word that is no longer there.
    public mutating func invalidateWarmup() {
        guard isWarmingUp else { return }
        residuals.removeAll()
    }

    /// Forgets everything — offset and warm-up both. For when tracking stops
    /// and the next session's posture is anyone's guess.
    public mutating func reset() {
        offset = nil
        residuals.removeAll()
        isWarmingUp = false
    }

    /// Feeds one residual (raw gaze point minus focal point) taken while
    /// playback runs. Ignored outside a warm-up.
    public mutating func ingest(_ residual: CGVector) {
        guard isWarmingUp else { return }
        residuals.append(residual)
        guard residuals.count >= warmupSampleCount else { return }
        offset = CGVector(
            dx: Self.median(residuals.map(\.dx)),
            dy: Self.median(residuals.map(\.dy)))
        residuals.removeAll()
        isWarmingUp = false
    }

    /// Nudges the offset toward a residual whose calibrated point already sat
    /// inside the focus radius — slow drift correction from samples that are
    /// evidently reading. No-op until established.
    public mutating func recentre(towards residual: CGVector) {
        guard let current = offset else { return }
        offset = CGVector(
            dx: current.dx + (residual.dx - current.dx) * recentreRate,
            dy: current.dy + (residual.dy - current.dy) * recentreRate)
    }

    /// Applies the learned offset; identity until established.
    public func calibrated(_ point: CGPoint) -> CGPoint {
        guard let offset else { return point }
        return CGPoint(x: point.x - offset.dx, y: point.y - offset.dy)
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        precondition(!values.isEmpty)
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}

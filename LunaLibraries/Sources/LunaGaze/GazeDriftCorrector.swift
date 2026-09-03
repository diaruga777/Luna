//
//  GazeDriftCorrector.swift
//  LunaGaze
//

import CoreGraphics
import Foundation

/// A bias nudge the caller should apply to its calibration.
public struct DriftCorrection: Equatable {
    /// Vector from the current estimate to where the reader is believed to be
    /// looking, in points.
    public let error: CGVector
    /// Fraction of `error` to move.
    public let gain: CGFloat
    /// Which axes may move.
    public let axes: GazeAffineCalibration.NudgeAxes

    public init(error: CGVector, gain: CGFloat, axes: GazeAffineCalibration.NudgeAxes) {
        self.error = error
        self.gain = gain
        self.axes = axes
    }
}

/// Keeps a calibration honest while reading, and says when it can no longer be.
///
/// Once the reading model is confident which sentence is being read, that
/// sentence's band is a free ground truth: the reader is, by definition,
/// looking at it. Pulling the vertical bias toward the band absorbs the slow
/// drift of a settling posture without ever asking for another sweep.
///
/// Three guards keep this from learning the wrong thing. It only runs while the
/// model is in gaze mode and confident. It ignores gaps too small to matter and
/// gaps too large to trust — a big gap means the reader looked away, not that
/// the calibration moved. And it never fights a scroll the user just made.
public struct GazeDriftCorrector {

    public struct Configuration: Equatable {
        /// Gap below which a correction is not worth making.
        public var minimumGapDegrees: CGFloat
        /// Gap above which the gap is a look-away, not a drift.
        public var maximumGapDegrees: CGFloat
        /// Gain used once, when a user scroll has settled.
        public var strongGain: CGFloat
        /// Gain used on the slow repeating correction.
        public var gentleGain: CGFloat
        /// How often the slow correction runs.
        public var gentleInterval: TimeInterval
        /// How long after a scroll the view counts as settled.
        public var scrollSettleDelay: TimeInterval
        /// Quality the strong correction needs.
        public var strongQuality: Double
        /// Quality the slow correction needs. Higher: it runs unprompted and
        /// forever, so it must be surer of itself.
        public var gentleQuality: Double
        /// Residual above which the calibration is suspect.
        public var residualDegrees: CGFloat
        /// How long the residual must stay bad before asking for a redo.
        public var residualHold: TimeInterval
        /// Relative change in view size that invalidates a fit.
        public var viewSizeDrift: CGFloat

        public init(
            minimumGapDegrees: CGFloat = 0.38,
            maximumGapDegrees: CGFloat = 3.6,
            strongGain: CGFloat = 0.12,
            gentleGain: CGFloat = 0.03,
            gentleInterval: TimeInterval = 1.2,
            scrollSettleDelay: TimeInterval = 0.5,
            strongQuality: Double = 0.5,
            gentleQuality: Double = 0.62,
            residualDegrees: CGFloat = 3.0,
            residualHold: TimeInterval = 10,
            viewSizeDrift: CGFloat = 0.2
        ) {
            self.minimumGapDegrees = minimumGapDegrees
            self.maximumGapDegrees = maximumGapDegrees
            self.strongGain = strongGain
            self.gentleGain = gentleGain
            self.gentleInterval = gentleInterval
            self.scrollSettleDelay = scrollSettleDelay
            self.strongQuality = strongQuality
            self.gentleQuality = gentleQuality
            self.residualDegrees = residualDegrees
            self.residualHold = residualHold
            self.viewSizeDrift = viewSizeDrift
        }
    }

    public let configuration: Configuration
    public let pointsPerDegree: CGFloat

    /// True once the fit is past saving and the reader should sweep again.
    public private(set) var needsRecalibration = false

    private var lastUserScroll: TimeInterval?
    private var correctedForScroll: TimeInterval?
    private var lastGentle: TimeInterval?
    private var badResidualSince: TimeInterval?

    public init(configuration: Configuration = Configuration(), pointsPerDegree: CGFloat) {
        self.configuration = configuration
        self.pointsPerDegree = pointsPerDegree
    }

    /// Records that the user moved the page. Corrections wait for it to settle.
    public mutating func userDidScroll(at time: TimeInterval) {
        lastUserScroll = time
    }

    /// Reports a new view size. A big enough change invalidates the fit.
    public mutating func viewDidResize(
        to size: CGSize, calibration: GazeAffineCalibration
    ) {
        if calibration.viewSizeDrift(from: size) > configuration.viewSizeDrift {
            needsRecalibration = true
        }
    }

    /// Clears the nag and the timers, for a fresh calibration.
    public mutating func reset() {
        needsRecalibration = false
        lastUserScroll = nil
        correctedForScroll = nil
        lastGentle = nil
        badResidualSince = nil
    }

    /// Offers one frame's worth of evidence.
    ///
    /// - Parameters:
    ///   - gaze: the calibrated estimate, in the same space as `bandCentreY`.
    ///   - bandCentreY: vertical centre of the line the reader is on, or nil
    ///     when the model has no active sentence.
    /// - Returns: the nudge to apply, or nil.
    public mutating func update(
        at time: TimeInterval,
        gaze: CGPoint?,
        bandCentreY: CGFloat?,
        state: ReadingState
    ) -> DriftCorrection? {
        updateRecalibrationNag(at: time, state: state)

        var strong = false
        if let scroll = lastUserScroll,
           time - scroll > configuration.scrollSettleDelay,
           correctedForScroll != scroll
        {
            correctedForScroll = scroll
            strong = true
        }
        if !strong {
            guard let last = lastGentle else {
                lastGentle = time
                return nil
            }
            guard time - last >= configuration.gentleInterval else { return nil }
            lastGentle = time
        }
        return correction(gaze: gaze, bandCentreY: bandCentreY, state: state, strong: strong)
    }

    private mutating func updateRecalibrationNag(at time: TimeInterval, state: ReadingState) {
        let limit = configuration.residualDegrees * pointsPerDegree
        guard state.mode == .gaze, state.residual > limit else {
            badResidualSince = nil
            return
        }
        if badResidualSince == nil { badResidualSince = time }
        if let since = badResidualSince, time - since > configuration.residualHold {
            needsRecalibration = true
        }
    }

    private func correction(
        gaze: CGPoint?, bandCentreY: CGFloat?, state: ReadingState, strong: Bool
    ) -> DriftCorrection? {
        guard state.mode == .gaze, let gaze, let bandCentreY else { return nil }
        let needed = strong ? configuration.strongQuality : configuration.gentleQuality
        guard state.quality >= needed else { return nil }
        let gap = abs(gaze.y - bandCentreY)
        guard gap >= configuration.minimumGapDegrees * pointsPerDegree,
              gap <= configuration.maximumGapDegrees * pointsPerDegree
        else { return nil }
        return DriftCorrection(
            error: CGVector(dx: 0, dy: bandCentreY - gaze.y),
            gain: strong ? configuration.strongGain : configuration.gentleGain,
            axes: .verticalOnly)
    }
}

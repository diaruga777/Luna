//
//  GazeGate.swift
//  LunaGaze
//

import CoreGraphics
import Foundation

/// Why the gaze signal is, or is not, usable right now.
public enum GateReason: String, Equatable {
    /// A face is tracked, the eyes are open, and the estimate lands on screen.
    case ok
    /// The eyes are closed. The estimate during a blink is meaningless.
    case blink
    /// No face has been seen for long enough to call it gone.
    case away
    /// The estimate lands well outside the display.
    case offScreen
}

/// Rolling judgement of "is the reader looking at the page right now".
///
/// The reading model freezes rather than guesses whenever this closes, so the
/// thresholds are deliberately forgiving: a single dropped frame must not stop
/// a reader mid-sentence, and a blink must not be read as a look-away.
public struct GazeGate {

    /// Blend-shape value above which an eye counts as closed.
    public let blinkThreshold: Double
    /// How long the face may be missing before the gate calls it away.
    public let faceLostDelay: TimeInterval
    /// How far outside the screen an estimate may land, in points.
    public let offScreenSlop: CGFloat
    /// The screen the estimate is judged against, in the SAME orientation as
    /// the point passed to `update(...)` — a landscape session must set this
    /// from `GazeScreenProjection.orientedSize(portraitSize:orientation:)`,
    /// never the portrait-fixed size a tracker reports in. `update(...)`
    /// compares `point` to this size axis-for-axis with no rotation of its
    /// own, so a mismatch here silently reads every sample as `.offScreen`.
    public var screenSize: CGSize

    /// The current verdict.
    public private(set) var reason: GateReason = .away

    /// True while the signal is usable.
    public var isOpen: Bool { reason == .ok }

    private var lastFaceTime: TimeInterval?

    public init(
        screenSize: CGSize,
        offScreenSlop: CGFloat,
        blinkThreshold: Double = 0.45,
        faceLostDelay: TimeInterval = 0.350
    ) {
        self.screenSize = screenSize
        self.offScreenSlop = offScreenSlop
        self.blinkThreshold = blinkThreshold
        self.faceLostDelay = faceLostDelay
    }

    /// Slop stated in degrees of visual angle: 1.5°.
    public init(
        screenSize: CGSize,
        pointsPerDegree: CGFloat,
        offScreenSlopDegrees: CGFloat = 1.5,
        blinkThreshold: Double = 0.45,
        faceLostDelay: TimeInterval = 0.350
    ) {
        self.init(
            screenSize: screenSize,
            offScreenSlop: offScreenSlopDegrees * pointsPerDegree,
            blinkThreshold: blinkThreshold,
            faceLostDelay: faceLostDelay)
    }

    public mutating func reset() {
        lastFaceTime = nil
        reason = .away
    }

    /// Feeds one frame. `point` is the calibrated estimate, or nil when the
    /// frame produced none.
    @discardableResult
    public mutating func update(
        faceTracked: Bool,
        blinkLeft: Double,
        blinkRight: Double,
        point: CGPoint?,
        at time: TimeInterval
    ) -> GateReason {
        if faceTracked { lastFaceTime = time }

        // A dropped frame is not an absence. Only a run of them is.
        if !faceTracked {
            let lost = lastFaceTime.map { time - $0 > faceLostDelay } ?? true
            reason = lost ? .away : .ok
            return reason
        }
        // Either eye closed is enough: the estimate needs both irises.
        if max(blinkLeft, blinkRight) > blinkThreshold {
            reason = .blink
            return reason
        }
        if let point, !isOnScreen(point) {
            reason = .offScreen
            return reason
        }
        reason = .ok
        return reason
    }

    private func isOnScreen(_ point: CGPoint) -> Bool {
        point.x >= -offScreenSlop && point.x <= screenSize.width + offScreenSlop
            && point.y >= -offScreenSlop && point.y <= screenSize.height + offScreenSlop
    }
}

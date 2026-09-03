//
//  GazeSample.swift
//  LunaGaze
//

import CoreGraphics
import Foundation

/// One estimate of where the reader is looking, in the coordinate space of the
/// view that owns the focal word.
public enum GazeSample: Equatable {
    /// A gaze point somewhere on the display's plane — possibly beyond its
    /// edges. The tracker emits the raw estimate; whether it counts as "on
    /// the display" is decided only after calibration removes the
    /// estimator's bias (`RSVPGazeCoordinator`).
    case point(CGPoint)
    /// The gaze ray never meets the display plane — the reader is confidently
    /// looking away from the device.
    case offScreen
    /// No usable face: the reader turned away, covered the camera, or the
    /// session dropped tracking. This is an unavailable signal, never a
    /// reason to pause playback.
    case faceLost
}

/// One ARKit frame's full report: the same estimate as `GazeSample`, plus the
/// blink state a `GazeGate` needs and `GazeSample` alone cannot carry.
///
/// Delivered through a second, optional `GazeTrackingDelegate` method — the
/// Reader's RSVP tracking has no use for blink and keeps seeing only
/// `GazeSample` through `gazeTracker(_:didProduce:)`.
public struct GazeFrame: Equatable {
    public let sample: GazeSample
    /// Blend-shape value for the left eye's blink, 0 (open) to 1 (closed).
    public let blinkLeft: Double
    /// Blend-shape value for the right eye's blink, 0 (open) to 1 (closed).
    public let blinkRight: Double
    /// Whether a face was tracked in this frame at all.
    public let isFaceTracked: Bool

    public init(sample: GazeSample, blinkLeft: Double, blinkRight: Double, isFaceTracked: Bool) {
        self.sample = sample
        self.blinkLeft = blinkLeft
        self.blinkRight = blinkRight
        self.isFaceTracked = isFaceTracked
    }
}

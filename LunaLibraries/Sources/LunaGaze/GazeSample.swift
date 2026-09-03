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

//
//  GazeDeviceClass.swift
//  LunaGaze
//

import Foundation

/// The device family the projection's points-per-inch table keys off.
///
/// A plain enum rather than `UIUserInterfaceIdiom`, so the geometry compiles
/// without UIKit. `.mac` has no front TrueDepth camera to project a gaze ray
/// from — no `GazeTrackerMaking` witness ever produces samples for it — but
/// the ppi table needs an answer for every case rather than a missing one.
/// `GazeDeviceClass(_:)` in `GazeUIKitBridging.swift` converts from the real
/// `UIUserInterfaceIdiom`.
public enum GazeDeviceClass: Equatable {
    case phone
    case pad
    case mac
}

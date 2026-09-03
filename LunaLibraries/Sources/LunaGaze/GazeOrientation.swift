//
//  GazeOrientation.swift
//  LunaGaze
//

import Foundation

/// Which edge of the portrait-fixed display currently sits at the top.
///
/// A plain enum rather than `UIInterfaceOrientation`, so the projection
/// geometry and the calibration store compile without UIKit. The Mac target
/// has no rotating display, so its own composition root can pass `.portrait`
/// throughout. `GazeOrientation(_:)` in `GazeUIKitBridging.swift` converts
/// from the real `UIInterfaceOrientation`.
public enum GazeOrientation: Equatable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight
}

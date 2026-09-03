//
//  GazeGate+ARKit.swift
//  LunaGaze
//

import ARKit
import Foundation

extension GazeGate {

    /// Left and right blink from an ARKit face anchor's blend shapes.
    ///
    /// The two eyes are reported apart, so the gate reads both and takes the
    /// worse: one closed iris is enough to spoil the estimate.
    public static func blink(
        from blendShapes: [ARFaceAnchor.BlendShapeLocation: NSNumber]
    ) -> (left: Double, right: Double) {
        (
            left: blendShapes[.eyeBlinkLeft]?.doubleValue ?? 0,
            right: blendShapes[.eyeBlinkRight]?.doubleValue ?? 0
        )
    }
}

//
//  ClipCaptureWidgetControl.swift
//  ClipCaptureWidget
//

import AppIntents
import SwiftUI
import WidgetKit

/// A Control Center / Lock Screen / Action button / Camera Control control that
/// launches Clip's locked-capture extension.
struct ClipCaptureWidgetControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.hpiddy.clip.capturecontrol") {
            ControlWidgetButton(action: ClipCameraCaptureIntent()) {
                Label("Pocket Capture", systemImage: "camera.aperture")
            }
        }
        .displayName("Clip Pocket Capture")
        .description("Capture a frame and trigger if it's a pocket shot.")
    }
}

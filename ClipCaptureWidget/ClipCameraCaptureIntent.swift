//
//  ClipCameraCaptureIntent.swift
//  ClipCaptureWidget
//
//  System intent that launches the LockedCameraCapture extension. Bound to the
//  control-widget button so the user can trigger it from the Camera Control button,
//  Lock Screen, Action button, or Control Center — without unlocking.
//

import AppIntents

struct ClipCaptureContext: Codable, Sendable {}

struct ClipCameraCaptureIntent: CameraCaptureIntent {
    static let title: LocalizedStringResource = "Clip Pocket Capture"
    static let description = IntentDescription("Capture a frame and check whether it's a pocket shot.")

    typealias AppContext = ClipCaptureContext
    static var appContext = ClipCaptureContext()

    func perform() async throws -> some IntentResult {
        .result()
    }
}

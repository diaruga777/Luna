//
//  ClipCaptureExtensionBundle.swift
//  ClipCapture
//
//  LockedCameraCapture extension: launched from the Camera Control button / Lock
//  Screen / Action button / Control Center WITHOUT unlocking. It captures a frame,
//  decides whether the scene is "pocket-dark", and fires the trigger (a notification)
//  — the reliable, instant path for "take a photo in my pocket and react".
//

import LockedCameraCapture
import SwiftUI

@main
struct ClipCaptureExtensionBundle: LockedCameraCaptureExtension {
    var body: some LockedCameraCaptureExtensionScene {
        LockedCameraCaptureUIScene { session in
            ClipCaptureView(session: session)
        }
    }
}

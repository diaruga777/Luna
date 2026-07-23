//
//  RescueModelSessionFactory.swift
//  LunaURLRescue
//

import Foundation

/// The SINGLE availability gate. Everything above the seam is OS-agnostic and
/// testable; only this factory names the OS/toolchain conditions. Mirrors
/// `ScreenCaptureModelSessionFactory` / `AudioTrimModelSessionFactory`.
///
/// - Xcode 27 (compiler ≥ 6.4) + iOS 27: the PCC-preferring conformer.
/// - iOS 26 (any toolchain that has FoundationModels): the on-device conformer.
/// - Otherwise (pre-26, or an Xcode-26.2 build with no model API): the stub.
public enum RescueModelSessionFactory {
    public static func makeDefault() -> RescueModelSession {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            return PrivateCloudRescueSession()
        }
        #endif
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return OnDeviceRescueSession()
        }
        #endif
        return UnavailableRescueModelSession()
    }
}

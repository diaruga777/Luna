//
//  ScreenCaptureModelSessionFactory.swift
//  LunaIntents
//

import Foundation

/// The ONE place that decides which `ScreenCaptureModelSession` conformer to
/// construct — mirrors `AudioTrimModelSessionFactory` so the compiler-version
/// + iOS-27-availability gate is never duplicated at call sites. Both
/// Provide Context's availability check and Save's extraction go through
/// this seam; everything above it is unit-testable with a fake conformer.
public enum ScreenCaptureModelSessionFactory {
    public static func makeDefault() -> ScreenCaptureModelSession {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            return FoundationModelsScreenCaptureSession()
        }
        #endif
        return UnavailableScreenCaptureSession()
    }
}

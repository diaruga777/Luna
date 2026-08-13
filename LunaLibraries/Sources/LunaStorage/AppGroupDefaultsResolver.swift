//
//  AppGroupDefaultsResolver.swift
//  LunaStorage
//

import Foundation

/// Resolves the `UserDefaults` for an App-Group-backed store: the injected test
/// override if one is set, otherwise the real App Group suite.
/// `SafariURLStore` and `ScreenshotDoublePressStore` both call this, but each
/// keeps its own `testDefaultsOverride` slot, so an override in one store can
/// never leak into the other.
public func resolvedAppGroupDefaults(appGroupID: String, testOverride: UserDefaults?) -> UserDefaults? {
    testOverride ?? UserDefaults(suiteName: appGroupID)
}

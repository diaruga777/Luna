//
//  AppGroupDefaultsResolver.swift
//  LunaStorage
//

import Foundation

/// Resolves an App-Group-backed static store's `UserDefaults`: the injected test
/// override when one is set, else the real App Group suite. Shared by
/// `SafariURLStore`/`ScreenshotDoublePressStore`'s otherwise-identical
/// test-injection hook — each store keeps its own `testDefaultsOverride` slot so
/// tests can't leak an override from one store into the other.
func resolvedAppGroupDefaults(appGroupID: String, testOverride: UserDefaults?) -> UserDefaults? {
    testOverride ?? UserDefaults(suiteName: appGroupID)
}

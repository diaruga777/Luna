//
//  AppIntentSettings.swift
//  LunaStorage
//

import LunaAppConfig
import Foundation

/// User preferences shared by the app UI and its background App Intent runs.
public enum AppIntentSettings {
    static let handleOnScreenURLsKey = "appIntents.handleOnScreenURLs"
    static var testDefaultsOverride: UserDefaults?

    private static var defaults: UserDefaults {
        testDefaultsOverride
            ?? UserDefaults(suiteName: AppConfig.appGroupID)
            ?? .standard
    }

    /// Whether Provide Context may save a complete URL supplied by Shortcuts'
    /// on-screen URL extraction. Defaults to ON. When disabled, the supplied
    /// value is ignored and the intent continues through its normal app-based
    /// screenshot or unsupported decision.
    public static var handleOnScreenURLs: Bool {
        get { (defaults.object(forKey: handleOnScreenURLsKey) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: handleOnScreenURLsKey) }
    }
}

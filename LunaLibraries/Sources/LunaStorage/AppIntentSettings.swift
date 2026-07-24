//
//  AppIntentSettings.swift
//  LunaStorage
//

import LunaAppConfig
import Foundation

/// User preferences shared by the app UI and its background App Intent runs.
public enum AppIntentSettings {
    static let handleOnScreenURLsKey = "appIntents.handleOnScreenURLs"
    static let returnsMediaToShortcutsKey = "returnMediaFromAppIntents"
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

    /// Whether the Action Button intents await a media download and hand the
    /// finished image/video back to Shortcuts. Defaults to ON. Lives here rather
    /// than with the media-download settings because the universal Shortcut &
    /// Safari settings screen (compiled into every app) presents it, and only
    /// media-capable apps link `LunaMediaDownload`.
    public static var returnsMediaToShortcuts: Bool {
        get { (defaults.object(forKey: returnsMediaToShortcutsKey) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: returnsMediaToShortcutsKey) }
    }

    /// The user-facing inverse of `returnsMediaToShortcuts`: "Download in
    /// Background" on means the intent returns immediately and the download
    /// continues behind a Live Activity. Defaults to OFF.
    public static var downloadMediaInBackground: Bool {
        get { !returnsMediaToShortcuts }
        set { returnsMediaToShortcuts = !newValue }
    }
}

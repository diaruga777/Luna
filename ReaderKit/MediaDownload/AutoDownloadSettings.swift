//
//  AutoDownloadSettings.swift
//  Clip
//

import Foundation

/// Per-platform "auto-download media to Photos on save" toggles, stored in the App
/// Group so every save path (app, intents, extensions) reads the same values.
/// Enabling a toggle requires Photos add permission (the settings screen prompts).
enum AutoDownloadSettings {
    private static let appGroupID = "group.com.hpiddy.clip"
    private static var defaults: UserDefaults { UserDefaults(suiteName: appGroupID) ?? .standard }

    /// Platforms that support auto-download, in display order.
    static let platforms: [ContentPlatform] = [.x, .instagram, .tiktok]

    private static func key(for platform: ContentPlatform) -> String {
        "autoDownloadMedia.\(platform.rawValue)"
    }

    static func isEnabled(for platform: ContentPlatform) -> Bool {
        defaults.bool(forKey: key(for: platform))
    }

    static func setEnabled(_ enabled: Bool, for platform: ContentPlatform) {
        defaults.set(enabled, forKey: key(for: platform))
    }
}

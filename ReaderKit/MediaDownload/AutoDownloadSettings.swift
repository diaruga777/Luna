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
    static let platforms: [ContentPlatform] = [.x, .instagram, .tiktok, .facebook]

    // Master switch for the action extension's media preview: when ON (default),
    // the preview auto-downloads the media inline; when OFF it starts in a pending
    // state with a manual download button. Stored in the App Group so both the app
    // (settings) and the extension (preview) read the same value. Distinct from the
    // per-platform `isEnabled` toggles, which gate auto-saving to Photos during
    // the main app's ingest funnel.
    private static let autoDownloadMediaKey = "autoDownloadMediaInPreview"

    /// Whether the action extension's media preview should auto-download inline.
    /// Defaults to ON (no stored value reads as enabled).
    static var autoDownloadMediaInPreview: Bool {
        get { (defaults.object(forKey: autoDownloadMediaKey) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: autoDownloadMediaKey) }
    }

    private static func key(for platform: ContentPlatform) -> String {
        "autoDownloadMedia.\(platform.rawValue)"
    }

    static func isEnabled(for platform: ContentPlatform) -> Bool {
        defaults.bool(forKey: key(for: platform))
    }

    static func setEnabled(_ enabled: Bool, for platform: ContentPlatform) {
        defaults.set(enabled, forKey: key(for: platform))
    }

    // Dedup: which URLs have already been auto-downloaded, so the in-process
    // download (share ext / intent) and the main-app ingest fallback never both
    // save the same post. A bounded recent list.
    private static let downloadedKey = "autoDownloadedURLs"
    private static let downloadedCap = 300

    static func wasDownloaded(_ urlString: String) -> Bool {
        (defaults.array(forKey: downloadedKey) as? [String])?.contains(urlString) ?? false
    }

    static func markDownloaded(_ urlString: String) {
        var list = (defaults.array(forKey: downloadedKey) as? [String]) ?? []
        guard !list.contains(urlString) else { return }
        list.append(urlString)
        if list.count > downloadedCap { list.removeFirst(list.count - downloadedCap) }
        defaults.set(list, forKey: downloadedKey)
    }
}

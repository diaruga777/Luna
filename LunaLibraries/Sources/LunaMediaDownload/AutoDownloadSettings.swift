//
//  AutoDownloadSettings.swift
//  Luna
//

import LunaAppConfig
import LunaModels
import Foundation

/// Per-platform "auto-download media to Photos on save" toggles, stored in the App
/// Group so every save path (app, intents, extensions) reads the same values.
/// Enabling a toggle requires Photos add permission (the settings screen prompts).
public enum AutoDownloadSettings {
    private static let appGroupID = AppConfig.appGroupID
    private static var defaults: UserDefaults { UserDefaults(suiteName: appGroupID) ?? .standard }

    private static let autoSaveDownloadsToPhotosKey = "autoSaveDownloadsToPhotos"

    /// Whether completed Downloader downloads should be saved into Photos.
    /// Defaults to ON so new installs use Photos-backed storage automatically.
    /// Surfaced to the user as `MediaStorageOption.photos` (see
    /// `MediaStorageSettings`), which is mutually exclusive with local retention.
    public static var autoSaveDownloadsToPhotos: Bool {
        get { (defaults.object(forKey: autoSaveDownloadsToPhotosKey) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: autoSaveDownloadsToPhotosKey) }
    }

    private static let wifiOnlyDownloadsKey = "wifiOnlyDownloads"

    /// Whether Downloader-owned downloads should be deferred while on cellular.
    /// Defaults to OFF (download on any network). Manual per-item retries
    /// (tap/long-press/viewer download button) always bypass this.
    public static var wifiOnlyDownloads: Bool {
        get { (defaults.object(forKey: wifiOnlyDownloadsKey) as? Bool) ?? false }
        set { defaults.set(newValue, forKey: wifiOnlyDownloadsKey) }
    }

    // URLs whose download was deferred specifically by `wifiOnlyDownloads` (not
    // just "undownloaded for some other reason", e.g. a platform's auto-download
    // toggle being off) — so the opportunistic Wi-Fi/launch/background-refresh
    // resume sweep only ever retries items IT deferred. A bounded recent list,
    // same shape as `autoDownloadedURLs`.
    private static let pendingWiFiDownloadsKey = "pendingWiFiDownloads"
    private static let pendingWiFiDownloadsCap = 300

    public static func markPendingWiFiDownload(_ urlString: String) {
        var list = (defaults.array(forKey: pendingWiFiDownloadsKey) as? [String]) ?? []
        guard !list.contains(urlString) else { return }
        list.append(urlString)
        if list.count > pendingWiFiDownloadsCap { list.removeFirst(list.count - pendingWiFiDownloadsCap) }
        defaults.set(list, forKey: pendingWiFiDownloadsKey)
    }

    public static func unmarkPendingWiFiDownload(_ urlString: String) {
        var list = (defaults.array(forKey: pendingWiFiDownloadsKey) as? [String]) ?? []
        list.removeAll { $0 == urlString }
        defaults.set(list, forKey: pendingWiFiDownloadsKey)
    }

    public static func pendingWiFiDownloadURLs() -> [String] {
        (defaults.array(forKey: pendingWiFiDownloadsKey) as? [String]) ?? []
    }

    /// Platforms that support auto-download, in display order.
    public static let platforms: [ContentPlatform] = [.x, .instagram, .tiktok, .facebook]

    // Master switch for the action extension's media preview: when ON (default),
    // the preview auto-downloads the media inline; when OFF it starts in a pending
    // state with a manual download button. Stored in the App Group so both the app
    // (settings) and the extension (preview) read the same value. Distinct from the
    // per-platform `isEnabled` toggles, which gate auto-saving to Photos during
    // the main app's ingest funnel.
    private static let autoDownloadMediaKey = "autoDownloadMediaInPreview"

    /// Whether the action extension's media preview should auto-download inline.
    /// Defaults to ON (no stored value reads as enabled).
    public static var autoDownloadMediaInPreview: Bool {
        get { (defaults.object(forKey: autoDownloadMediaKey) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: autoDownloadMediaKey) }
    }

    /// The single "Download automatically" choice Downloader Settings shows, over
    /// the two prefs that back it (`autoDownloadMediaInPreview` +
    /// `wifiOnlyDownloads`). Never means nothing downloads on its own; the two
    /// on-values differ only in whether cellular downloads wait for Wi-Fi.
    public static var policy: AutoDownloadPolicy {
        get {
            guard autoDownloadMediaInPreview else { return .never }
            return wifiOnlyDownloads ? .wifiOnly : .always
        }
        set {
            autoDownloadMediaInPreview = newValue != .never
            wifiOnlyDownloads = newValue == .wifiOnly
        }
    }

    private static func key(for platform: ContentPlatform) -> String {
        "autoDownloadMedia.\(platform.rawValue)"
    }

    public static func isEnabled(for platform: ContentPlatform) -> Bool {
        defaults.bool(forKey: key(for: platform))
    }

    public static func setEnabled(_ enabled: Bool, for platform: ContentPlatform) {
        defaults.set(enabled, forKey: key(for: platform))
    }

    // Dedup: which URLs have already been auto-downloaded, so the in-process
    // download (share ext / intent) and the main-app ingest fallback never both
    // save the same post. A bounded recent list.
    private static let downloadedKey = "autoDownloadedURLs"
    private static let downloadedCap = 300

    public static func wasDownloaded(_ urlString: String) -> Bool {
        (defaults.array(forKey: downloadedKey) as? [String])?.contains(urlString) ?? false
    }

    public static func markDownloaded(_ urlString: String) {
        var list = (defaults.array(forKey: downloadedKey) as? [String]) ?? []
        guard !list.contains(urlString) else { return }
        list.append(urlString)
        if list.count > downloadedCap { list.removeFirst(list.count - downloadedCap) }
        defaults.set(list, forKey: downloadedKey)
    }

    public static func unmarkDownloaded(_ urlString: String) {
        var list = (defaults.array(forKey: downloadedKey) as? [String]) ?? []
        list.removeAll { $0 == urlString }
        defaults.set(list, forKey: downloadedKey)
    }
}

/// The "Download automatically" choices: whether saved media downloads on its
/// own, and on which networks.
public enum AutoDownloadPolicy: CaseIterable, Sendable {
    case never
    case always
    case wifiOnly

    public var displayName: String {
        switch self {
        case .never: return "Never"
        case .always: return "Always"
        case .wifiOnly: return "On Wi-Fi Only"
        }
    }
}

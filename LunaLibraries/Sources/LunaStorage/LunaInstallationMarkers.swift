//
//  LunaInstallationMarkers.swift
//  LunaStorage
//
//  Moved from LunaMediaDownload: this is kind-neutral App-Group bookkeeping
//  (every app writes its own marker at launch), so it lives with the other
//  App-Group stores instead of dragging the media-download module into
//  article/product-only apps.
//

import LunaAppConfig
import Foundation

/// App-Group installation evidence used for cross-app Downloader behavior.
/// Markers intentionally survive uninstall: "was installed" is sufficient.
public enum LunaInstallationMarkers {
    public static let downloaderKey = "lunaInstalled.downloader"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: AppConfig.appGroupID) ?? .standard
    }

    public static var downloaderWasInstalled: Bool {
        defaults.bool(forKey: downloaderKey)
    }

    public static func recordInstalled(surfaceIdentifier: String) {
        defaults.set(true, forKey: "lunaInstalled.\(surfaceIdentifier)")
    }

    public static func wasInstalled(surfaceIdentifier: String) -> Bool {
        defaults.bool(forKey: "lunaInstalled.\(surfaceIdentifier)")
    }
}

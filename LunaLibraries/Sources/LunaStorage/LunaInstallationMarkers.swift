//
//  LunaInstallationMarkers.swift
//  LunaStorage
//
//  Kind-neutral App-Group bookkeeping (every app writes its own marker at
//  launch). It lives here, with the other App-Group stores, rather than in a
//  kind module, so linking it never drags the media-download module into an
//  article- or product-only app.
//

import LunaAppConfig
import Foundation

/// App-Group installation evidence used for cross-app Downloader behavior.
/// Markers intentionally survive uninstall: "was installed" is sufficient.
public enum LunaInstallationMarkers {
    public static let downloaderKey = "lunaInstalled.downloader"

    private static var defaults: UserDefaults {
        resolvedAppGroupDefaults(appGroupID: AppConfig.appGroupID, testOverride: nil) ?? .standard
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

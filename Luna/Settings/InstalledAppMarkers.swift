//
//  InstalledAppMarkers.swift
//  Luna
//

import LunaReadingListUI
import LunaStorage
import Foundation

/// App-Group markers recording which Luna apps exist on this device. Each app
/// writes its own marker at launch; the Safari extensions' native handlers read
/// the raw key strings (`lunaInstalled.<surface>` — the extensions don't share a
/// framework) to decide which sibling apps a page button can deep-link into,
/// e.g. "Track in Luna" needs Price Tracker and the paywall unlock needs Reader.
///
/// A marker can go stale after an uninstall (App Group data outlives any one
/// app); the extensions treat that as best-effort — the shared store still
/// surfaces a saved item on its proper surface.
enum InstalledAppMarkers {
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: ReadingListStore.appGroupID) ?? .standard
    }

    /// Records the running app's surface as installed. Called at every launch.
    static func recordCurrentApp() {
        defaults.set(true, forKey: key(for: AppSurfaceConfig.current))
    }

    /// `lunaInstalled.<surface>` — the suffix matches the app's bundle-id suffix.
    static func key(for surface: AppSurface) -> String {
        switch surface {
        case .reader: return "lunaInstalled.reader"
        case .downloader: return "lunaInstalled.downloader"
        case .priceTracker: return "lunaInstalled.pricetracker"
        }
    }
}

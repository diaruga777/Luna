//
//  InstalledAppMarkers.swift
//  Luna
//

import LunaModels
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
    /// Records the running app's surface as installed. Called at every launch.
    static func recordCurrentApp() {
        LunaInstallationMarkers.recordInstalled(
            surfaceIdentifier: LunaApp.current.storageIdentifier)
    }

}

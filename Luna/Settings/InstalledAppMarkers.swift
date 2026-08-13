//
//  InstalledAppMarkers.swift
//  Luna
//

import LunaModels
import LunaStorage
import Foundation

/// App-Group markers recording which Luna apps exist on this device. Each app
/// writes its own marker at launch. The Safari extensions' native handlers
/// read the raw key strings (`lunaInstalled.<surface>` — the extensions share
/// no framework) to decide which sibling apps a page button can deep-link
/// into: for example, "Track in Luna" needs Price Tracker, and the paywall
/// unlock needs Reader.
///
/// A marker can go stale after an uninstall, since App Group data outlives
/// any one app. The extensions treat that as best effort: the shared store
/// still surfaces a saved item on its proper surface.
enum InstalledAppMarkers {
    /// Records the running app's surface as installed. Called at every launch.
    static func recordCurrentApp() {
        LunaInstallationMarkers.recordInstalled(
            surfaceIdentifier: LunaApp.current.storageIdentifier)
    }

}

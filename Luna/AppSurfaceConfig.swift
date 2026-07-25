//
//  AppSurfaceConfig.swift
//  Luna
//

import LunaModels
import LunaReadingListUI
import Foundation

/// Which standalone Luna app this bundle is, derived from the bundle identifier
/// (`com.hsanabria.luna[.<surface>]` — the bare prefix is the central Luna app).
/// The apps share one codebase, one App Group, and one shared store; this is the
/// single switch that tells a running process which content surface it presents.
///
/// Deriving from the bundle id keeps the apps a single source tree with no per-app
/// Swift or Info.plist branching — the only per-app input is the bundle id, which is
/// already driven by `Config/Luna.xcconfig` + each app's `PRODUCT_BUNDLE_IDENTIFIER`.
enum AppSurfaceConfig {
    static var current: AppSurface {
        switch LunaApp.current {
        case .luna: return .all
        case .reader: return .reader
        case .downloader: return .downloader
        case .priceTracker: return .priceTracker
        }
    }
}

extension AppSurface {
    /// Bare per-surface identifier (`"luna"` / `"reader"` / `"downloader"` /
    /// `"pricetracker"`) — the same suffix convention as
    /// `InstalledAppMarkers.key(for:)` — used as the raw key segment for
    /// LunaStorage's per-surface stores. `AppSurface` lives in
    /// `LunaReadingListUI`, which already depends on `LunaStorage`, so those
    /// stores take this bare string rather than the enum itself (importing
    /// `LunaReadingListUI` back into `LunaStorage` would cycle).
    var storageIdentifier: String {
        switch self {
        case .all: return LunaApp.luna.storageIdentifier
        case .reader: return LunaApp.reader.storageIdentifier
        case .downloader: return LunaApp.downloader.storageIdentifier
        case .priceTracker: return LunaApp.priceTracker.storageIdentifier
        }
    }
}

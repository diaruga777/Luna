//
//  InteropSurface.swift
//  LunaInterop
//

import LunaURLClassification
import Foundation

/// Which standalone Luna app OWNS a given save. Mirrors `AppSurface`
/// (`LunaReadingListUI`) one-for-one, but `LunaInterop` is a low-tier module
/// (linked into the share/action extensions and, eventually, StoreKit purchase
/// code) that can't depend on the UIKit feature libraries `AppSurface` lives in
/// — so this is a second, dependency-light enum with the same three cases and
/// the same bundle-id-derived `current`. `Luna/AppSurfaceConfig.swift`'s
/// `AppSurface.storageIdentifier` and this type's `storageIdentifier` MUST stay
/// textually identical (`"reader"` / `"downloader"` / `"pricetracker"`) since
/// both key the same App Group storage (installed markers, per-surface
/// onboarding).
public enum InteropSurface: String, Equatable, CaseIterable, Sendable {
    case reader
    case downloader
    case priceTracker

    /// Derives the running process's surface from `Bundle.main.bundleIdentifier`
    /// (`com.<namespace>.<app>` for an app, `com.<namespace>.<app>.share` /
    /// `.action` / `.safari` for its extensions). Contains-checks rather than
    /// `hasSuffix` so it resolves correctly from inside an extension bundle too
    /// — an app-extension's bundle id is never bare `....downloader`, it's
    /// `....downloader.share` etc.
    public static var current: InteropSurface {
        surface(forBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
    }

    /// Testable seam for `current`'s bundle-id parsing.
    public static func surface(forBundleIdentifier identifier: String) -> InteropSurface {
        if matches(identifier, suffix: ".downloader") { return .downloader }
        if matches(identifier, suffix: ".pricetracker") { return .priceTracker }
        return .reader
    }

    private static func matches(_ identifier: String, suffix: String) -> Bool {
        identifier.hasSuffix(suffix) || identifier.contains(suffix + ".")
    }

    /// UI-facing name. Prose elsewhere always says just "Luna" (the family name);
    /// this is the one place that names a SPECIFIC sibling app, because the
    /// interop prompt must tell the user exactly which app to install/open.
    public var displayName: String {
        switch self {
        case .reader: return "Luna Reader"
        case .downloader: return "Luna Downloader"
        case .priceTracker: return "Luna Price Tracker"
        }
    }

    /// The bare per-surface identifier, matching `AppSurface.storageIdentifier`
    /// and `InstalledAppMarkers.key(for:)`'s suffix.
    public var storageIdentifier: String {
        switch self {
        case .reader: return "reader"
        case .downloader: return "downloader"
        case .priceTracker: return "pricetracker"
        }
    }

    /// `lunaInstalled.<surface>` — MUST stay byte-identical to
    /// `Luna/Settings/InstalledAppMarkers.key(for:)` and the raw strings the
    /// Safari extension's native handlers read directly.
    public var installedMarkerKey: String {
        "lunaInstalled.\(storageIdentifier)"
    }

    /// This surface's `luna*://` deep-link scheme (`LunaDeepLink`).
    public var deepLinkScheme: String {
        switch self {
        case .reader: return LunaDeepLink.readerScheme
        case .downloader: return LunaDeepLink.downloaderScheme
        case .priceTracker: return LunaDeepLink.priceTrackerScheme
        }
    }

    /// Whether this surface's app has ever recorded itself as installed on this
    /// device (App Group marker, best-effort — see `InteropInstallationMarkers`).
    public var isInstalled: Bool {
        InteropInstallationMarkers.isInstalled(self)
    }
}

/// Reads the App-Group "app X was installed" markers `InstalledAppMarkers`
/// (`Luna/Settings/InstalledAppMarkers.swift`) and `LunaInstallationMarkers`
/// (`LunaMediaDownload`) write. Duplicated here (rather than depending on
/// `LunaMediaDownload`, a services-tier module) to keep `LunaInterop` in the
/// same low tier as `LunaAppConfig`/`LunaModels`/`LunaURLClassification` — but
/// the KEY STRINGS must stay exactly compatible, since the Safari extension's
/// native handlers read these same raw keys without linking any Swift module.
public enum InteropInstallationMarkers {
    public static func isInstalled(
        _ surface: InteropSurface, defaults: UserDefaults = InteropAppGroupDefaults.current
    ) -> Bool {
        defaults.bool(forKey: surface.installedMarkerKey)
    }
}

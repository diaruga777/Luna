import Foundation

/// Which standalone Luna app a running process belongs to — the central
/// all-content **Luna** app or one of the three single-content apps. Derived
/// from the bundle identifier, using contains-matching so it also resolves
/// from inside an app's extensions (`…reader.share`, `…downloader.safari`, …).
///
/// The central Luna app's bundle id is the bare product prefix
/// (`com.hsanabria.luna`) with no content suffix, so "no suffix" resolves to
/// `.luna` — which is also the right default for the unit-test host.
public enum LunaApp: CaseIterable, Equatable {
    /// The central Luna app — accepts and processes every content kind.
    case luna
    case reader
    case downloader
    case priceTracker

    public static var current: LunaApp {
        detect(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    public static func detect(bundleIdentifier: String?) -> LunaApp {
        let identifier = (bundleIdentifier ?? "").lowercased()
        if identifier.contains(".downloader") { return .downloader }
        if identifier.contains(".pricetracker") { return .priceTracker }
        if identifier.contains(".reader") { return .reader }
        return .luna
    }

    /// Bare per-app identifier used as the raw key segment for App-Group
    /// storage (installed markers, per-surface stores, …).
    public var storageIdentifier: String {
        switch self {
        case .luna: return "luna"
        case .reader: return "reader"
        case .downloader: return "downloader"
        case .priceTracker: return "pricetracker"
        }
    }

    /// The user-visible app name.
    public var displayName: String {
        switch self {
        case .luna: return L10n.string("Luna")
        case .reader: return L10n.string("Luna Reader")
        case .downloader: return L10n.string("Luna Downloader")
        case .priceTracker: return L10n.string("Luna Price Tracker")
        }
    }

    /// App-Group marker key recording that this app has run on this device.
    /// The Safari extensions' native handlers read these raw strings (they
    /// don't share a framework), so the format is part of the App-Group
    /// contract: `lunaInstalled.<storageIdentifier>`.
    public var installedMarkerKey: String {
        "lunaInstalled." + storageIdentifier
    }
}

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

    /// The user-visible app name. `self` names WHICH app to show the name of —
    /// not necessarily the running one (`UnsupportedSaveCopy` shows a foreign
    /// app's name) — so this resolves through the suffix table for `self`
    /// rather than reading `L10n.string`'s own `.current` default.
    public var displayName: String {
        L10n.string("LunaApp_displayName", for: self)
    }

    /// Per-kind capability. The central Luna app handles everything; each
    /// single-content app handles exactly one kind. This is the runtime mirror of
    /// a build-time fact (which per-kind SwiftPM products the target links), and
    /// the same three-way split `SurfaceSupport` gates on.
    public var handlesArticles: Bool { self == .luna || self == .reader }
    public var handlesMedia: Bool { self == .luna || self == .downloader }
    public var handlesProducts: Bool { self == .luna || self == .priceTracker }

    /// Whether this app does email at all: connecting an account, sending saves to
    /// contacts, and importing shares/newsletters from a mailbox. Downloader and
    /// Price Tracker share by plain URL through the system share sheet instead, so
    /// they have no account to connect, no Contacts screen, and no mail import —
    /// see `claudedocs/social-sharing.md`.
    public var sharesByEmail: Bool { self == .luna || self == .reader }

    /// App-Group marker key recording that this app has run on this device.
    /// The Safari extensions' native handlers read these raw strings (they
    /// don't share a framework), so the format is part of the App-Group
    /// contract: `lunaInstalled.<storageIdentifier>`.
    public var installedMarkerKey: String {
        "lunaInstalled." + storageIdentifier
    }

    /// The suffix `L10n` appends to a base key for THIS app's own override,
    /// e.g. `"Foo_Reader"`. The central Luna app's own tier is `"Core"` rather
    /// than `"Luna"` because `"_Luna"` is reserved for the universal fallback
    /// every base key must define — see `L10n.string`.
    public var ownLocalizationSuffix: String {
        switch self {
        case .luna: return "Core"
        case .reader: return "Reader"
        case .downloader: return "Downloader"
        case .priceTracker: return "PriceTracker"
        }
    }
}

import Foundation
import LunaAppConfig

/// Which standalone Luna app a running process belongs to — the central
/// all-content **Luna** app or one of the four standalone apps. Derived
/// from the bundle identifier, using contains-matching so it also resolves
/// from inside an app's extensions (`…reader.share`, `…downloader.safari`, …).
///
/// The central Luna app's bundle id is the bare product prefix
/// (`com.hsanabria.luna`) with no content suffix, so "no suffix" resolves to
/// `.luna` — which is also the right default for the unit-test host.
public enum LunaApp: CaseIterable, Equatable, Hashable, Sendable {
    /// The central Luna app — accepts and processes every content kind.
    case luna
    case reader
    case downloader
    case priceTracker
    /// Standalone encrypted file vault; not a URL content-kind surface.
    case vault
    /// Standalone Markdown writing app (claudedocs/plans/writer-app.md); not a
    /// URL content-kind surface and not on the shared saves store.
    case writer

    public static var current: LunaApp {
        detect(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    /// The standalone apps' product order used when the central Luna app needs
    /// one representative lesson. Keep this separate from `allCases`: the
    /// central app is a host, not one of the sibling products being ranked.
    public static let onboardingRankedSiblings: [LunaApp] = [
        .reader, .downloader, .priceTracker,
    ]

    /// The URL/content-kind apps that share the legacy shell, onboarding and
    /// staged-screen catalogs. Vault is a standalone file surface and joins
    /// these systems only when central integration is implemented explicitly.
    public static let legacyContentApps: [LunaApp] = [
        .luna, .reader, .downloader, .priceTracker,
    ]

    public static func detect(bundleIdentifier: String?) -> LunaApp {
        let identifier = (bundleIdentifier ?? "").lowercased()
        if identifier.contains(".downloader") { return .downloader }
        if identifier.contains(".pricetracker") { return .priceTracker }
        if identifier.contains(".reader") { return .reader }
        if identifier.contains(".vault") { return .vault }
        if identifier.contains(".writer") { return .writer }
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
        case .vault: return "vault"
        case .writer: return "writer"
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
    /// Vault owns arbitrary files rather than URL-classified saves.
    public var handlesVaultFiles: Bool { self == .vault }

    /// Whether this app does email at all: connecting an account, sending saves to
    /// contacts, and importing shares/newsletters from a mailbox. Downloader and
    /// Price Tracker share by plain URL through the system share sheet instead, so
    /// they have no account to connect, no Contacts screen, and no mail import —
    /// see `claudedocs/social-sharing.md`.
    public var sharesByEmail: Bool { self == .luna || self == .reader }

    /// Whether this app transcribes a plugin's recording into a reader article
    /// (`claudedocs/plans/transcription-plugins.md`). Only central Luna runs
    /// plugins, so only it can queue or finish a transcription; the Transcribe
    /// affordances read this before they show.
    public var transcribesMedia: Bool { self == .luna }

    /// The file extension a Luna file addressed to this app carries
    /// (`claudedocs/plans/ai-flows.md` §3). An LLM is asked to name its reply
    /// `<title>.<fileExtension>`, and the matching UTI is what the app's
    /// document type claims. Vault and Writer take no Luna file.
    public var fileExtension: String? {
        switch self {
        case .luna: return "luna"
        case .reader: return "lunar"
        case .downloader: return "lunad"
        case .priceTracker: return "lunas"
        case .vault, .writer: return nil
        }
    }

    /// The exported UTI a Luna file addressed to this app carries, as the
    /// shared `Luna/Info.plist` declares it: `<prefix>.file` for the central
    /// app, `<prefix>.<storageIdentifier>.file` for a single-content app.
    /// The central app's type is what the other three conform to, so one
    /// document type covers the family (`claudedocs/luna-file.md`).
    public var fileTypeIdentifier: String? {
        guard fileExtension != nil else { return nil }
        let prefix = AppConfig.productBundlePrefix
        return self == .luna ? "\(prefix).file" : "\(prefix).\(storageIdentifier).file"
    }

    /// Every Luna file type this app opens — the mirror of
    /// `acceptedFileExtensions`. The three sibling types come first because
    /// they CONFORM to the central one, so a first-match search that met
    /// `<prefix>.file` first would report every Luna file as the central kind.
    public var acceptedFileTypeIdentifiers: [String] {
        switch self {
        case .luna:
            return ([.reader, .downloader, .priceTracker, .luna] as [LunaApp])
                .compactMap { $0.fileTypeIdentifier }
        default: return fileTypeIdentifier.map { [$0] } ?? []
        }
    }

    /// Every extension this app opens: the central app opens the whole
    /// family's files, a single-content app only its own.
    public var acceptedFileExtensions: [String] {
        switch self {
        case .luna: return LunaApp.allCases.compactMap { $0.fileExtension }
        default: return fileExtension.map { [$0] } ?? []
        }
    }

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
        case .vault: return "Vault"
        case .writer: return "Writer"
        }
    }

    /// This app's identity in the Action Button double-save system, or nil for
    /// the two apps that don't arm it. Only the two article-file apps
    /// (`handlesArticles`, and specifically Luna/Reader rather than a future
    /// third) let a repeat press build and send an article. This is the ONE
    /// place that decision is made: `ActionButtonIntentSupport.doubleSaveSurface`
    /// and `SettingsViewController`'s own property both read it here instead of
    /// each hand-writing the same `switch`.
    public var doubleSaveSurface: DoubleSaveSurface? {
        DoubleSaveSurface(app: self)
    }
}

/// Which app's Action Button double-save setting a save press is scoped to.
/// Parsed once from `LunaApp.doubleSaveSurface`. `rawValue` is used only at
/// `DoubleSaveActionStore`'s defaults-key boundary — never to carry this value
/// through the intent/ingest pipeline as a bare `String`; that pipeline must
/// pass the typed enum instead.
public enum DoubleSaveSurface: String, Codable, Equatable, Sendable {
    case luna
    case reader

    public init?(app: LunaApp) {
        switch app {
        case .luna: self = .luna
        case .reader: self = .reader
        case .downloader, .priceTracker, .vault, .writer: return nil
        }
    }
}

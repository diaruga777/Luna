import Foundation

/// The shared lookup point for user-facing copy shipped by Luna's library modules.
///
/// A call site names a bare, descriptive KEY — never the English text itself —
/// e.g. an onboarding util-card headline might be keyed `Onboarding_Util_headline`.
/// At runtime that key is resolved against `Localizable.strings` by trying, in order:
///
///   1. `"<key>_<app's own suffix>"` — `Core` for the central Luna app, else
///      `Reader` / `Downloader` / `PriceTracker` (`LunaApp.ownLocalizationSuffix`).
///   2. `"<key>_Luna"` — the universal default every base key MUST define.
///
/// So a string all four apps show identically needs only a `_Luna` entry;
/// giving one app its own wording is adding one more line
/// (`"<key>_Reader" = "…";`) with no Swift change at all — which is also why
/// no call site should ever hand-roll a `switch LunaApp.current { … }` around
/// an `L10n.string` call: that switch IS this resolution, done worse and
/// invisibly to the strings file. Keeping the catalog in `LunaModels` gives
/// every app and extension one translation source while still resolving
/// strings from the SwiftPM resource bundle.
///
/// `for app:` resolves a NAMED app's copy rather than the running process's
/// own — for showing another app's text (`LunaApp.displayName`) and for tests
/// that verify a surface's wording without faking a bundle identifier.
public enum L10n {
    public static func string(_ key: String, _ args: CVarArg...) -> String {
        resolvedString(key, for: .current, args: args)
    }

    public static func string(_ key: String, for app: LunaApp, _ args: CVarArg...) -> String {
        resolvedString(key, for: app, args: args)
    }

    /// `nil` when neither the app's own entry nor `_Luna` exists — for a
    /// caller that needs to tell "no such key" apart from "found, but empty"
    /// (an ordered list of per-app entries with no fixed count, e.g.
    /// `OnboardingSafariExtensionCopy.explainerChunks`, reads `"<prefix>1"`,
    /// `"<prefix>2"`, … until this returns `nil`).
    public static func stringIfPresent(_ key: String, for app: LunaApp = .current) -> String? {
        guard let resolved = resolvedKeyIfPresent(key, app: app) else { return nil }
        return NSLocalizedString(resolved, tableName: nil, bundle: .module, value: "", comment: "")
    }

    /// A deferred lookup for system APIs that accept `LocalizedStringResource`
    /// rather than a resolved `String`, such as ActivityKit alerts. Has no
    /// `args` form: every current call site is static text, and the app-suffix
    /// choice is made eagerly here (in our own process, where `app` is known)
    /// rather than left to whichever process ends up rendering the resource.
    public static func resource(_ key: String) -> LocalizedStringResource {
        resource(key, for: .current)
    }

    public static func resource(_ key: String, for app: LunaApp) -> LocalizedStringResource {
        LocalizedStringResource(
            String.LocalizationValue(resolvedKey(key, app: app)),
            bundle: .atURL(Bundle.module.bundleURL))
    }

    private static func resolvedString(_ key: String, for app: LunaApp, args: [CVarArg]) -> String {
        let format = NSLocalizedString(
            resolvedKey(key, app: app), tableName: nil, bundle: .module, value: "", comment: "")
        guard !args.isEmpty else { return format }
        return String(format: format, arguments: args)
    }

    /// `"<key>_<ownSuffix>"` if that entry exists in the table, else
    /// `"<key>_Luna"` — the entry every base key is required to define.
    /// `LocalizableStringsTests` enforces that every key `L10n` is ever called
    /// with has a `_Luna` line, so this never surfaces a key with no entry.
    private static func resolvedKey(_ key: String, app: LunaApp) -> String {
        resolvedKeyIfPresent(key, app: app) ?? "\(key)_Luna"
    }

    private static func resolvedKeyIfPresent(_ key: String, app: LunaApp) -> String? {
        let own = "\(key)_\(app.ownLocalizationSuffix)"
        if hasEntry(own) { return own }
        let fallback = "\(key)_Luna"
        return hasEntry(fallback) ? fallback : nil
    }

    private static func hasEntry(_ key: String) -> Bool {
        NSLocalizedString(key, tableName: nil, bundle: .module, value: key, comment: "") != key
    }
}

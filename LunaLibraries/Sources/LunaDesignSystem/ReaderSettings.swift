//
//  ReaderSettings.swift
//  Luna
//

import LunaAppConfig
import LunaModels
import UIKit

/// RSVP speed-reader display granularity: one word at a time, or whole phrases.
public enum RSVPDisplayMode: String {
    case words
    case phrases
}

/// User-adjustable reading preferences, persisted in the App Group so the
/// share-extension reader honors the same settings as the main app.
public enum ReaderSettings {
    public static let appGroupID = AppConfig.appGroupID
    private static var defaults: UserDefaults { UserDefaults(suiteName: appGroupID) ?? .standard }

    private static let wpmKey = "rsvpBaseWPM"
    private static let fontScaleKey = "readerFontScale"
    private static let serifKey = "readerSerifFont"
    private static let fontKey = "readerFont"
    private static let lastReaderModeKey = "lastReaderMode"
    private static let rsvpModeKey = "rsvpDisplayMode"
    private static let preloadDepthKey = "linkPreloadDepth"
    private static let preloadWiFiOnlyKey = "preloadWiFiOnly"
    private static let accentKey = "readerAccentColor"
    private static let migratedKey = "readerSettingsMigratedToAppGroup"
    private static let linkPreviewPositionsKey = "linkRSVPPreviewWordPositions"

    /// One-time copy of settings previously kept in standard defaults into the
    /// App Group (so the extension sees them). Call once at app launch.
    public static func migrateFromStandardIfNeeded() {
        guard !defaults.bool(forKey: migratedKey) else { return }
        let standard = UserDefaults.standard
        for key in [wpmKey, fontScaleKey, serifKey, lastReaderModeKey] {
            if let value = standard.object(forKey: key) { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: migratedKey)
    }

    /// The reader mode the user last used — the default for new articles that
    /// don't yet have a per-article preference. The retired standalone
    /// "highlight" (chunking) mode now lives as the RSVP "Phrases" sub-mode, so a
    /// persisted `highlight` resolves to `rsvp` (the reader opens it in Phrases).
    public static var lastReaderMode: ReadingListItem.ReaderMode {
        get {
            let stored = ReadingListItem.ReaderMode(
                rawValue: defaults.string(forKey: lastReaderModeKey) ?? "") ?? .scroll
            return stored == .highlight ? .rsvp : stored
        }
        set { defaults.set(newValue.rawValue, forKey: lastReaderModeKey) }
    }

    /// Whether the RSVP reader shows one word at a time ("Words") or whole
    /// phrases ("Phrases", the former chunk-highlight mode's engine). Persisted
    /// so the choice sticks across articles, like the base WPM.
    public static var rsvpMode: RSVPDisplayMode {
        get { RSVPDisplayMode(rawValue: defaults.string(forKey: rsvpModeKey) ?? "") ?? .words }
        set { defaults.set(newValue.rawValue, forKey: rsvpModeKey) }
    }

    /// How many levels of links to background-preload from a saved article so the
    /// inline link viewer opens instantly. 0 = off; clamped 0…5; default 2 (preload
    /// the links on the saved page and the links one hop beyond them). App Group so
    /// the action extension can record the intent and the main app resume it.
    public static let preloadDepthRange: ClosedRange<Int> = 0...5
    public static var preloadDepth: Int {
        get {
            guard defaults.object(forKey: preloadDepthKey) != nil else { return 2 }
            let stored = defaults.integer(forKey: preloadDepthKey)
            return min(max(stored, preloadDepthRange.lowerBound), preloadDepthRange.upperBound)
        }
        set {
            defaults.set(
                min(max(newValue, preloadDepthRange.lowerBound), preloadDepthRange.upperBound),
                forKey: preloadDepthKey)
        }
    }

    /// Whether background link preloading is restricted to Wi-Fi. Orthogonal to
    /// `preloadDepth` (depth alone still governs whether/how deep preloading
    /// runs; this only decides which networks it may use — a no-op when depth
    /// is 0). Defaults to OFF: preload crawls run on any network, including
    /// cellular. Turning this ON restores the historical Wi-Fi-only behavior.
    public static var preloadWiFiOnly: Bool {
        get { (defaults.object(forKey: preloadWiFiOnlyKey) as? Bool) ?? false }
        set { defaults.set(newValue, forKey: preloadWiFiOnlyKey) }
    }

    /// Reader text size multiplier (Safari-Reader-style Aa control).
    public static var fontScale: Double {
        get {
            let value = defaults.double(forKey: fontScaleKey)
            return value == 0 ? 1.0 : value
        }
        set { defaults.set(newValue, forKey: fontScaleKey) }
    }

    /// The system Dynamic Type scale (1.0 at the default Large category),
    /// clamped so the largest accessibility sizes still fit the reader layout —
    /// the card column is narrow, and an unclamped 3× body size would leave
    /// only a couple of words per line.
    public static var systemTypeScale: Double {
        let scaled = UIFontMetrics(forTextStyle: .body).scaledValue(for: 100)
        return min(max(Double(scaled) / 100, 0.85), 1.6)
    }

    /// The scale reader text actually renders at: the manual size choice
    /// multiplied by the clamped system accessibility scale.
    public static var effectiveFontScale: Double {
        fontScale * systemTypeScale
    }

    /// Legacy serif (New York) vs sans toggle — superseded by `font`, kept
    /// only so `font` can honor a choice made before the typeface list existed.
    public static var useSerifFont: Bool {
        get { (defaults.object(forKey: serifKey) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: serifKey) }
    }

    /// The reader typeface. Readers who set the old serif toggle keep their
    /// look until they pick from the new list.
    public static var font: ReaderFont {
        get {
            if let stored = defaults.string(forKey: fontKey),
               let font = ReaderFont(rawValue: stored) {
                return font
            }
            return useSerifFont ? .newYork : .system
        }
        set { defaults.set(newValue.rawValue, forKey: fontKey) }
    }

    /// Base words-per-minute for the RSVP reader. Per-word display time is
    /// computed from this, scaled by word length and punctuation pauses.
    public static var baseWPM: Double {
        get {
            let value = defaults.double(forKey: wpmKey)
            return value == 0 ? 300 : value
        }
        set { defaults.set(newValue, forKey: wpmKey) }
    }

    /// Resume positions for links previewed without first saving them. Saved reading-list
    /// items continue to use their normal `lastWordIndex`; this URL-keyed fallback gives
    /// transient link previews the same exit/resume behavior.
    public static func linkPreviewWordIndex(for canonicalURLString: String) -> Int {
        let positions = defaults.dictionary(forKey: linkPreviewPositionsKey) as? [String: Int]
        return max(0, positions?[canonicalURLString] ?? 0)
    }

    public static func setLinkPreviewWordIndex(_ index: Int, for canonicalURLString: String) {
        var positions = defaults.dictionary(forKey: linkPreviewPositionsKey) as? [String: Int] ?? [:]
        positions[canonicalURLString] = max(0, index)
        // Keep this tiny even after years of browsing; dictionary order is not meaningful,
        // so trim arbitrary old entries once the practical ceiling is crossed.
        if positions.count > 500 {
            for key in positions.keys.prefix(positions.count - 500) { positions.removeValue(forKey: key) }
        }
        defaults.set(positions, forKey: linkPreviewPositionsKey)
    }

    /// The reader highlight/focus accent (RSVP reticule + ORP letter + scroll/
    /// chunk highlight). Configurable; defaults to blue.
    public static var accent: ReaderAccent {
        get { ReaderAccent(rawValue: defaults.string(forKey: accentKey) ?? "") ?? .blue }
        set { defaults.set(newValue.rawValue, forKey: accentKey) }
    }
}

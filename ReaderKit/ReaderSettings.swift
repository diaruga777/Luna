//
//  ReaderSettings.swift
//  Clip
//

import Foundation

/// RSVP speed-reader display granularity: one word at a time, or whole phrases.
enum RSVPDisplayMode: String {
    case words
    case phrases
}

/// User-adjustable reading preferences, persisted in the App Group so the
/// share-extension reader honors the same settings as the main app.
enum ReaderSettings {
    static let appGroupID = "group.com.hpiddy.clip"
    private static var defaults: UserDefaults { UserDefaults(suiteName: appGroupID) ?? .standard }

    private static let wpmKey = "rsvpBaseWPM"
    private static let eyeTrackingKey = "eyeTrackingEnabled"
    private static let highlightGazeWordKey = "highlightGazeWord"
    private static let fontScaleKey = "readerFontScale"
    private static let serifKey = "readerSerifFont"
    private static let readingTimeKey = "showReadingTime"
    private static let progressKey = "showReadingProgress"
    private static let lastReaderModeKey = "lastReaderMode"
    private static let rsvpModeKey = "rsvpDisplayMode"
    private static let accentKey = "readerAccentColor"
    private static let archiveOverlayAlphaKey = "archiveOverlayAlpha"
    private static let migratedKey = "readerSettingsMigratedToAppGroup"

    /// Opacity of the cover over the archive web view (experimental/diagnostic):
    /// 0.99 = effectively hidden (default); lower it to see the archive flow
    /// through the overlay. Clamped to 0.2…0.99.
    static let archiveOverlayAlphaRange: ClosedRange<Double> = 0.2...0.99
    static var archiveOverlayAlpha: Double {
        get {
            guard let stored = defaults.object(forKey: archiveOverlayAlphaKey) as? Double else { return 0.99 }
            return min(max(stored, archiveOverlayAlphaRange.lowerBound), archiveOverlayAlphaRange.upperBound)
        }
        set {
            defaults.set(
                min(max(newValue, archiveOverlayAlphaRange.lowerBound), archiveOverlayAlphaRange.upperBound),
                forKey: archiveOverlayAlphaKey)
        }
    }

    /// One-time copy of settings previously kept in standard defaults into the
    /// App Group (so the extension sees them). Call once at app launch.
    static func migrateFromStandardIfNeeded() {
        guard !defaults.bool(forKey: migratedKey) else { return }
        let standard = UserDefaults.standard
        for key in [wpmKey, eyeTrackingKey, fontScaleKey, serifKey,
                    readingTimeKey, progressKey, lastReaderModeKey] {
            if let value = standard.object(forKey: key) { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: migratedKey)
    }

    /// Whether gaze tracking may run while reading (and whether stored gaze
    /// estimates may be used). Defaults to on; only takes effect on devices
    /// with TrueDepth face tracking.
    static var eyeTrackingEnabled: Bool {
        get { (defaults.object(forKey: eyeTrackingKey) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: eyeTrackingKey) }
    }

    /// When on (and eye tracking is active), the scrolling reader highlights the
    /// word the gaze tracker currently estimates you're looking at. Off by
    /// default — it's a live, slightly distracting affordance.
    static var highlightGazeWord: Bool {
        get { defaults.bool(forKey: highlightGazeWordKey) }
        set { defaults.set(newValue, forKey: highlightGazeWordKey) }
    }

    /// The reader mode the user last used — the default for new articles that
    /// don't yet have a per-article preference. The retired standalone
    /// "highlight" (chunking) mode now lives as the RSVP "Phrases" sub-mode, so a
    /// persisted `highlight` resolves to `rsvp` (the reader opens it in Phrases).
    static var lastReaderMode: ReadingListItem.ReaderMode {
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
    static var rsvpMode: RSVPDisplayMode {
        get { RSVPDisplayMode(rawValue: defaults.string(forKey: rsvpModeKey) ?? "") ?? .words }
        set { defaults.set(newValue.rawValue, forKey: rsvpModeKey) }
    }

    /// Reader text size multiplier (Safari-Reader-style Aa control).
    static var fontScale: Double {
        get {
            let value = defaults.double(forKey: fontScaleKey)
            return value == 0 ? 1.0 : value
        }
        set { defaults.set(newValue, forKey: fontScaleKey) }
    }

    /// Serif (New York-style) vs sans-serif reader type.
    static var useSerifFont: Bool {
        get { (defaults.object(forKey: serifKey) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: serifKey) }
    }

    /// Show estimated reading time in the list (Pocket-style).
    static var showReadingTime: Bool {
        get { (defaults.object(forKey: readingTimeKey) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: readingTimeKey) }
    }

    /// Show reading progress percentage in the list (Pocket-style).
    static var showReadingProgress: Bool {
        get { (defaults.object(forKey: progressKey) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: progressKey) }
    }

    /// Base words-per-minute for the RSVP reader. Per-word display time is
    /// computed from this, scaled by word length and punctuation pauses.
    static var baseWPM: Double {
        get {
            let value = defaults.double(forKey: wpmKey)
            return value == 0 ? 300 : value
        }
        set { defaults.set(newValue, forKey: wpmKey) }
    }

    /// The reader highlight/focus accent (RSVP reticule + ORP letter + scroll/
    /// chunk highlight). Configurable; defaults to blue.
    static var accent: ReaderAccent {
        get { ReaderAccent(rawValue: defaults.string(forKey: accentKey) ?? "") ?? .blue }
        set { defaults.set(newValue.rawValue, forKey: accentKey) }
    }
}

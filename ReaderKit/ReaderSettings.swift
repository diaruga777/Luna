//
//  ReaderSettings.swift
//  Clip
//

import Foundation

/// User-adjustable reading preferences, persisted in the App Group so the
/// share-extension reader honors the same settings as the main app.
enum ReaderSettings {
    static let appGroupID = "group.com.hpiddy.clip"
    private static var defaults: UserDefaults { UserDefaults(suiteName: appGroupID) ?? .standard }

    private static let wpmKey = "rsvpBaseWPM"
    private static let eyeTrackingKey = "eyeTrackingEnabled"
    private static let fontScaleKey = "readerFontScale"
    private static let serifKey = "readerSerifFont"
    private static let readingTimeKey = "showReadingTime"
    private static let progressKey = "showReadingProgress"
    private static let lastReaderModeKey = "lastReaderMode"
    private static let accentKey = "readerAccentColor"
    private static let migratedKey = "readerSettingsMigratedToAppGroup"

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

    /// The reader mode the user last used — the default for new articles that
    /// don't yet have a per-article preference.
    static var lastReaderMode: ReadingListItem.ReaderMode {
        get {
            ReadingListItem.ReaderMode(
                rawValue: defaults.string(forKey: lastReaderModeKey) ?? "") ?? .scroll
        }
        set { defaults.set(newValue.rawValue, forKey: lastReaderModeKey) }
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

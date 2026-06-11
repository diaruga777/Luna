//
//  ReaderSettings.swift
//  Clip
//

import Foundation

/// User-adjustable reading preferences, persisted in standard defaults.
enum ReaderSettings {
    private static let wpmKey = "rsvpBaseWPM"
    private static let eyeTrackingKey = "eyeTrackingEnabled"

    /// Whether gaze tracking may run while reading (and whether stored gaze
    /// estimates may be used). Defaults to on; only takes effect on devices
    /// with TrueDepth face tracking.
    static var eyeTrackingEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: eyeTrackingKey) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: eyeTrackingKey) }
    }

    private static let fontScaleKey = "readerFontScale"
    private static let serifKey = "readerSerifFont"
    private static let readingTimeKey = "showReadingTime"
    private static let progressKey = "showReadingProgress"

    /// Reader text size multiplier (Safari-Reader-style Aa control).
    static var fontScale: Double {
        get {
            let value = UserDefaults.standard.double(forKey: fontScaleKey)
            return value == 0 ? 1.0 : value
        }
        set { UserDefaults.standard.set(newValue, forKey: fontScaleKey) }
    }

    /// Serif (New York-style) vs sans-serif reader type.
    static var useSerifFont: Bool {
        get { (UserDefaults.standard.object(forKey: serifKey) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: serifKey) }
    }

    /// Show estimated reading time in the list (Pocket-style).
    static var showReadingTime: Bool {
        get { (UserDefaults.standard.object(forKey: readingTimeKey) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: readingTimeKey) }
    }

    /// Show reading progress percentage in the list (Pocket-style).
    static var showReadingProgress: Bool {
        get { (UserDefaults.standard.object(forKey: progressKey) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: progressKey) }
    }

    /// Base words-per-minute for the RSVP reader. Per-word display time is
    /// computed from this, scaled by word length and punctuation pauses.
    static var baseWPM: Double {
        get {
            let value = UserDefaults.standard.double(forKey: wpmKey)
            return value == 0 ? 300 : value
        }
        set {
            UserDefaults.standard.set(newValue, forKey: wpmKey)
        }
    }
}

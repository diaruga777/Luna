//
//  VoiceModelStore.swift
//  ReaderKit
//

import LunaAppConfig
import Foundation

/// Shared, App-Group-backed state for the text-to-speech system: the one-time
/// first-run prompt flag and the catch-up voice-card dismissal flag, plus a
/// convenience check for whether an enhanced Apple voice is installed. Readable
/// from BOTH the main app and the extensions (they share the same App Group).
///
/// Read-aloud uses an enhanced Apple voice when one is installed and the built-in
/// system voice otherwise; Luna never downloads or stores voice models itself
/// (enhanced voices are installed by the user in iOS Settings).
public enum VoiceModelStore {

    public static let appGroupID = AppConfig.appGroupID
    private static var defaults: UserDefaults { UserDefaults(suiteName: appGroupID) ?? .standard }

    private static let hasSeenVoicePromptKey = "hasSeenVoicePrompt"
    private static let hasDismissedVoiceCatchUpKey = "hasDismissedVoiceCatchUp"

    // MARK: - Availability

    /// Whether the user has installed an enhanced/premium Apple voice for the
    /// locale (read-aloud uses it automatically when present).
    public static var isAppleEnhancedInstalled: Bool { AppleEnhancedEngine.hasInstalledEnhancedVoice }

    // MARK: - First-run prompt

    /// Whether the one-time "better voices available" prompt has been shown. Set
    /// the first time the user starts read-aloud.
    public static var hasSeenVoicePrompt: Bool {
        get { defaults.bool(forKey: hasSeenVoicePromptKey) }
        set { defaults.set(newValue, forKey: hasSeenVoicePromptKey) }
    }

    // MARK: - Catch-up voice card

    /// Whether the user has dismissed the catch-up "install enhanced voices"
    /// card. Once true, the card (and its contribution to the catch-up dot) is
    /// suppressed. Defaults to `false`.
    public static var hasDismissedVoiceCatchUp: Bool {
        get { defaults.bool(forKey: hasDismissedVoiceCatchUpKey) }
        set { defaults.set(newValue, forKey: hasDismissedVoiceCatchUpKey) }
    }
}

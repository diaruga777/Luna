//
//  AudioSettings.swift
//  LunaAudioPlayback
//

import LunaAppConfig
import Foundation

/// User-adjustable read-aloud playback preferences, persisted in the App
/// Group — same shape/pattern as `LunaDesignSystem.ReaderSettings` and
/// `LunaReaderUI.VoiceModelStore` (see `claudedocs/audio-playback-plan.md`).
/// Read by `AudioPlaybackCenter` (autoplay chain, rate) and by
/// `AudioScriptPipeline`/`ExtensionAudioScriptResolver` (`isIntelligentTrimmingEnabled`).
public enum AudioSettings {
    public static let appGroupID = AppConfig.appGroupID
    private static var defaults: UserDefaults { UserDefaults(suiteName: appGroupID) ?? .standard }

    private static let autoplayKey = "audioAutoplayEnabled"
    private static let intelligentTrimmingKey = "audioIntelligentTrimmingEnabled"
    private static let rateKey = "audioPreferredRate"

    /// The only rates the legacy reader's rate-cycling control
    /// (`SpeechController.cycleRate`) and this module's `cycleRate` ever land
    /// on — kept identical between the two so switching between the legacy
    /// and new playback paths never surprises the user with an off-menu rate.
    public static let rateSteps: [Float] = [0.8, 1.0, 1.2, 1.5]

    /// Whether finishing an article auto-advances to the next unread one
    /// (mark-read, chime, "Now Reading — <title>" announcement, chime, next
    /// article). Default ON. Re-read fresh at every autoplay boundary by
    /// `AudioPlaybackCenter` — never cached — so toggling it mid-article takes
    /// effect at the very next decision point.
    public static var isAutoplayEnabled: Bool {
        get { (defaults.object(forKey: autoplayKey) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: autoplayKey) }
    }

    /// Whether the optional on-device FoundationModels pass may refine the
    /// heuristic audio-trimming script (Phase 4). Default ON; the heuristic
    /// pass always runs regardless of this setting. Defined now so Phase 4
    /// has nothing to add to the settings surface.
    public static var isIntelligentTrimmingEnabled: Bool {
        get { (defaults.object(forKey: intelligentTrimmingKey) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: intelligentTrimmingKey) }
    }

    /// User-selected playback speed multiplier, always clamped to the
    /// nearest of `rateSteps`. Default `1.0`. `0` is not a member of
    /// `rateSteps`, so it doubles safely as the "never set" sentinel (the
    /// same convention `ReaderSettings.fontScale`/`baseWPM` use).
    public static var preferredRate: Float {
        get {
            let stored = defaults.float(forKey: rateKey)
            return stored == 0 ? 1.0 : nearestRateStep(stored)
        }
        set { defaults.set(nearestRateStep(newValue), forKey: rateKey) }
    }

    private static func nearestRateStep(_ value: Float) -> Float {
        rateSteps.min(by: { abs($0 - value) < abs($1 - value) }) ?? 1.0
    }
}

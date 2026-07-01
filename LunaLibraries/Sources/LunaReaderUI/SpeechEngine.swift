//
//  SpeechEngine.swift
//  ReaderKit
//

import AVFoundation

/// Abstraction over a text-to-speech backend.
///
/// Both of Luna's engines drive an `AVSpeechSynthesizer` (basic &
/// appleEnhanced). An engine therefore expresses itself by CONFIGURING the
/// utterance the caller will speak: choosing the voice and adjusting the rate.
/// Keeping synthesis on `AVSpeechSynthesizer` preserves
/// `willSpeakRangeOfSpeechString` callbacks, so the reader's word-by-word
/// highlighting keeps working unchanged for every engine.
public protocol SpeechEngine {
    /// Which kind this engine implements.
    var kind: VoiceEngineKind { get }

    /// Whether the engine can actually produce speech right now (model present /
    /// suitable voice installed). Checked at play time so the controller can fall
    /// back to a safe engine.
    var isAvailable: Bool { get }

    /// Configures `utterance` (voice, rate) before it is handed to the
    /// `AVSpeechSynthesizer`. `rate` is the already-computed `utterance.rate`
    /// the caller wants; engines may keep or adjust it.
    func configure(_ utterance: AVSpeechUtterance, rate: Float)
}

public extension SpeechEngine {
    /// Default rate handling: apply the caller's rate unchanged. Engines that
    /// need a different default (e.g. a slower neural voice) override `configure`.
    public func applyDefaultRate(_ utterance: AVSpeechUtterance, rate: Float) {
        utterance.rate = min(rate, AVSpeechUtteranceMaximumSpeechRate)
    }
}

/// Builds the concrete engine for a kind, used by `SpeechController` and RSVP.
public enum SpeechEngineFactory {
    /// Returns an engine for `kind`. The returned engine is NOT guaranteed
    /// available — callers must consult `isAvailable` and fall back.
    public static func make(_ kind: VoiceEngineKind) -> SpeechEngine {
        switch kind {
        case .basic: return BasicSpeechEngine()
        case .appleEnhanced: return AppleEnhancedEngine()
        }
    }

    /// Resolves the engine to read aloud with: the enhanced Apple voice when the
    /// user has installed one, otherwise the always-available basic system voice.
    /// The result is always usable. Behaves identically in the app and its
    /// extensions.
    public static func resolveSelected() -> SpeechEngine {
        let enhanced = AppleEnhancedEngine()
        return enhanced.isAvailable ? enhanced : BasicSpeechEngine()
    }
}

// MARK: - Basic

/// The original behavior: the system default voice via `AVSpeechSynthesizer`.
/// Always available.
public struct BasicSpeechEngine: SpeechEngine {
    public let kind: VoiceEngineKind = .basic
    public var isAvailable: Bool { true }

    public func configure(_ utterance: AVSpeechUtterance, rate: Float) {
        // `nil` voice = the system default voice (and the simulator-safe choice,
        // matching the prior `SpeechVoice.best` behavior on the simulator).
        utterance.voice = SpeechVoice.systemDefault
        applyDefaultRate(utterance, rate: rate)
    }
}

// MARK: - Apple Enhanced

/// Uses the best installed *enhanced/premium* `AVSpeechSynthesisVoice` for the
/// locale. Available only when such a voice has been installed by the user in
/// iOS Settings → Accessibility → Spoken Content → Voices (apps cannot download
/// Apple voices programmatically).
public struct AppleEnhancedEngine: SpeechEngine {
    public let kind: VoiceEngineKind = .appleEnhanced
    public var isAvailable: Bool { Self.hasInstalledEnhancedVoice }

    public func configure(_ utterance: AVSpeechUtterance, rate: Float) {
        utterance.voice = Self.bestEnhancedVoice ?? SpeechVoice.systemDefault
        applyDefaultRate(utterance, rate: rate)
    }

    /// The best enhanced/premium voice for the current language, or `nil` if the
    /// user hasn't installed one.
    public static var bestEnhancedVoice: AVSpeechSynthesisVoice? {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let prefix = String(language.prefix(2))
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language || $0.language.hasPrefix(prefix) }
        let exactLanguage = candidates.filter { $0.language == language }
        for pool in [exactLanguage, candidates] {
            if let premium = pool.first(where: { $0.quality == .premium }) { return premium }
            if let enhanced = pool.first(where: { $0.quality == .enhanced }) { return enhanced }
        }
        return nil
    }

    /// Whether any enhanced/premium voice for the locale is installed.
    public static var hasInstalledEnhancedVoice: Bool { bestEnhancedVoice != nil }
}

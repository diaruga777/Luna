//
//  SpeechEngine.swift
//  ReaderKit
//

import AVFoundation

/// Abstraction over a text-to-speech backend.
///
/// All of Clip's current engines ultimately drive an `AVSpeechSynthesizer`
/// (basic & appleEnhanced directly; piper & kokoro fall back to one until a
/// neural runtime is vendored — see `// TODO(neural-tts)`). An engine therefore
/// expresses itself by CONFIGURING the utterance the caller will speak: choosing
/// the voice and adjusting the rate. Keeping synthesis on `AVSpeechSynthesizer`
/// preserves `willSpeakRangeOfSpeechString` callbacks, so the reader's
/// word-by-word highlighting keeps working unchanged for every engine.
///
/// When a real neural runtime arrives, an engine can instead override
/// `synthesize(text:)` to return rendered audio; until then that entry point is
/// optional and the AVSpeech path is used.
protocol SpeechEngine {
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

extension SpeechEngine {
    /// Default rate handling: apply the caller's rate unchanged. Engines that
    /// need a different default (e.g. a slower neural voice) override `configure`.
    func applyDefaultRate(_ utterance: AVSpeechUtterance, rate: Float) {
        utterance.rate = min(rate, AVSpeechUtteranceMaximumSpeechRate)
    }
}

/// Builds the concrete engine for a kind, used by `SpeechController` and RSVP.
enum SpeechEngineFactory {
    /// Returns an engine for `kind`. The returned engine is NOT guaranteed
    /// available — callers must consult `isAvailable` and fall back.
    static func make(_ kind: VoiceEngineKind) -> SpeechEngine {
        switch kind {
        case .basic: return BasicSpeechEngine()
        case .appleEnhanced: return AppleEnhancedEngine()
        case .piper: return PiperEngine()
        case .kokoro: return KokoroEngine()
        }
    }

    /// Resolves the engine the user selected, falling back to a usable one if
    /// the selection isn't currently available. The result is always usable.
    ///
    /// EXTENSION POLICY: inside an app extension (share / action extension) we
    /// NEVER run a neural engine (piper/kokoro) — even once a real ONNX runtime
    /// is vendored, loading a ~60–90 MB model would blow the extension's tight
    /// memory budget and get the extension jetsam-killed mid-read. Extensions
    /// always speak with appleEnhanced (if installed) or basic. (Today neural
    /// engines fall back to Apple voices anyway, so this only bites once real
    /// neural inference lands — hence enforcing it here, not later.)
    static func resolveSelected() -> SpeechEngine {
        if isAppExtension {
            let enhanced = AppleEnhancedEngine()
            return enhanced.isAvailable ? enhanced : BasicSpeechEngine()
        }
        let selected = make(VoiceModelStore.selectedEngine)
        if selected.isAvailable { return selected }
        let enhanced = AppleEnhancedEngine()
        return enhanced.isAvailable ? enhanced : BasicSpeechEngine()
    }

    /// True when running inside an app extension (its bundle is an `.appex`).
    private static var isAppExtension: Bool {
        Bundle.main.bundleURL.pathExtension == "appex"
    }
}

// MARK: - Basic

/// The original behavior: the system default voice via `AVSpeechSynthesizer`.
/// Always available.
struct BasicSpeechEngine: SpeechEngine {
    let kind: VoiceEngineKind = .basic
    var isAvailable: Bool { true }

    func configure(_ utterance: AVSpeechUtterance, rate: Float) {
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
struct AppleEnhancedEngine: SpeechEngine {
    let kind: VoiceEngineKind = .appleEnhanced
    var isAvailable: Bool { Self.hasInstalledEnhancedVoice }

    func configure(_ utterance: AVSpeechUtterance, rate: Float) {
        utterance.voice = Self.bestEnhancedVoice ?? SpeechVoice.systemDefault
        applyDefaultRate(utterance, rate: rate)
    }

    /// The best enhanced/premium voice for the current language, or `nil` if the
    /// user hasn't installed one.
    static var bestEnhancedVoice: AVSpeechSynthesisVoice? {
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
    static var hasInstalledEnhancedVoice: Bool { bestEnhancedVoice != nil }
}

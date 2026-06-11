//
//  SpeechVoice.swift
//  Clip
//

import AVFoundation

/// Picks the best on-device voice for read-aloud: premium > enhanced > default
/// quality for the user's language (no downloads — only what's installed).
enum SpeechVoice {
    static let best: AVSpeechSynthesisVoice? = {
        #if targetEnvironment(simulator)
        // High-quality voice assets are listed but don't reliably render in
        // the simulator (synthesis silently stalls) — use the system default.
        return nil
        #else
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let prefix = String(language.prefix(2))
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language || $0.language.hasPrefix(prefix) }
        let exactLanguage = candidates.filter { $0.language == language }

        for pool in [exactLanguage, candidates] {
            if let premium = pool.first(where: { $0.quality == .premium }) { return premium }
            if let enhanced = pool.first(where: { $0.quality == .enhanced }) { return enhanced }
        }
        return AVSpeechSynthesisVoice(language: language)
        #endif
    }()
}

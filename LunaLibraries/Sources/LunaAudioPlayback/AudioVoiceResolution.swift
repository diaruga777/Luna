//
//  AudioVoiceResolution.swift
//  LunaAudioPlayback
//

import AVFoundation

/// Minimal, standalone replica of `LunaReaderUI`'s voice-resolution logic
/// (`SpeechVoice.systemDefault` + `AppleEnhancedEngine.bestEnhancedVoice`), used
/// only by `SpeechRenderer`.
///
/// Deliberately duplicated rather than imported: `LunaReaderUI` is a large
/// module (App-Group, HTML classification, fetch/bypass, archive reader,
/// ingest, transitions, SwiftSoup, …) and Phase 1 of the audio rebuild must not
/// pull that whole graph into `LunaAudioPlayback` just to reuse ~20 lines of
/// voice-picking. `LunaReaderUI` does not (yet) depend on `LunaAudioPlayback`
/// either, so there's no cycle either way — this is purely about not
/// over-declaring dependencies. If the two ever need to share more logic, that
/// consolidation is a separate, deliberate refactor (not part of this phase).
enum AudioVoiceResolution {

    /// The voice `SpeechRenderer` renders with: the best installed
    /// enhanced/premium voice for the current language, falling back to the
    /// system default (`nil` — the synthesizer's own default) when none is
    /// installed, or unconditionally on the simulator.
    ///
    /// The simulator special-case mirrors `SpeechVoice.systemDefault`: some
    /// voice assets listed as available there don't reliably render (synthesis
    /// silently produces no audio), and an `AVSpeechUtterance` with a `nil`
    /// voice always renders something.
    static func resolveBestVoice() -> AVSpeechSynthesisVoice? {
        #if targetEnvironment(simulator)
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
    }
}

//
//  SpeechVoice.swift
//  Luna
//

import AVFoundation

/// Picks on-device voices for read-aloud. The multi-engine system
/// (`SpeechEngine`) now owns voice selection per engine; this enum holds the
/// shared, no-download primitives those engines build on.
public enum SpeechVoice {

    /// The system default voice for the current language. On the simulator we
    /// return `nil` (= the synthesizer's own default) because the high-quality
    /// voice assets listed there don't reliably render (synthesis silently
    /// stalls). An `AVSpeechUtterance` with a `nil` voice always speaks.
    public static var systemDefault: AVSpeechSynthesisVoice? {
        #if targetEnvironment(simulator)
        return nil
        #else
        return AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        #endif
    }
}

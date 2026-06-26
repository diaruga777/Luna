//
//  VoiceEngineKind.swift
//  ReaderKit
//

import Foundation

/// The available text-to-speech engines, in roughly ascending quality order.
///
/// - `basic`: the system default `AVSpeechSynthesisVoice`. Always available, no
///   download. This is Clip's original read-aloud behavior.
/// - `appleEnhanced`: an `AVSpeechSynthesizer` using the best installed
///   *enhanced/premium* voice for the locale. "Availability" here means the user
///   has installed such a voice in iOS Settings (apps can't download Apple
///   voices programmatically).
/// - `piper` / `kokoro`: neural TTS models downloaded at runtime from Hugging
///   Face into the App Group. The download/select/delete lifecycle is fully real;
///   neural inference is deferred — see `PiperEngine`/`KokoroEngine`.
enum VoiceEngineKind: String, CaseIterable, Codable, Sendable {
    case basic
    case appleEnhanced
    case piper
    case kokoro

    /// User-facing name shown in the Voice settings screen.
    var displayName: String {
        switch self {
        case .basic: return "Standard"
        case .appleEnhanced: return "Enhanced (Apple)"
        case .piper: return "Piper (Neural)"
        case .kokoro: return "Kokoro (Neural)"
        }
    }

    /// A one-line description of the engine for the settings subtitle.
    var summary: String {
        switch self {
        case .basic:
            return "The built-in system voice. Always available."
        case .appleEnhanced:
            return "A higher-quality Apple voice, if one is installed."
        case .piper:
            return "Compact neural voice downloaded from Hugging Face."
        case .kokoro:
            return "High-quality neural voice downloaded from Hugging Face."
        }
    }

    /// Whether this engine requires downloading a model into the App Group
    /// before it can be selected. (`basic`/`appleEnhanced` use OS-resident
    /// voices and are never "downloaded" by Clip.)
    var requiresDownload: Bool {
        switch self {
        case .basic, .appleEnhanced: return false
        case .piper, .kokoro: return true
        }
    }
}

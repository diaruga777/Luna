//
//  VoiceEngineKind.swift
//  ReaderKit
//

import Foundation

/// The available text-to-speech engines, in ascending quality order.
///
/// - `basic`: the system default `AVSpeechSynthesisVoice`. Always available, no
///   install. This is Clip's original read-aloud behavior and the fallback when
///   no enhanced voice is present.
/// - `appleEnhanced`: an `AVSpeechSynthesizer` using the best installed
///   *enhanced/premium* voice for the locale. "Availability" here means the user
///   has installed such a voice in iOS Settings (apps can't download Apple
///   voices programmatically).
enum VoiceEngineKind: String, CaseIterable, Codable, Sendable {
    case basic
    case appleEnhanced

    /// User-facing name shown in the Voice settings screen.
    var displayName: String {
        switch self {
        case .basic: return "Standard"
        case .appleEnhanced: return "Enhanced (Apple)"
        }
    }

    /// A one-line description of the engine for the settings subtitle.
    var summary: String {
        switch self {
        case .basic:
            return "The built-in system voice. Always available."
        case .appleEnhanced:
            return "A higher-quality Apple voice, if one is installed."
        }
    }
}

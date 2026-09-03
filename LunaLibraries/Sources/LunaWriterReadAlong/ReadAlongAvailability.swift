//
//  ReadAlongAvailability.swift
//  LunaWriterReadAlong
//

import Foundation
import LunaGaze
import LunaWriterVoice

/// Whether each half of read-along can run in this process at all.
///
/// The two halves are independent: a device with no TrueDepth camera still
/// takes spoken comments, and a locale with no on-device speech model still
/// tracks reading.
public struct ReadAlongAvailability: Equatable {

    /// TrueDepth hardware, in a host app rather than an app extension.
    public let gaze: Bool
    public let voice: Bool
    /// Why voice is unavailable; nil while it is available.
    public let voiceReason: SpeechUnavailability?

    public init(gaze: Bool, voice: Bool, voiceReason: SpeechUnavailability?) {
        self.gaze = gaze
        self.voice = voice
        self.voiceReason = voiceReason
    }

    /// Asks the device and the transcriber.
    public static func resolve(transcriber: SpeechTranscribing?) -> ReadAlongAvailability {
        let voice = transcriber?.isAvailable ?? false
        return ReadAlongAvailability(
            gaze: GazeTrackingAvailability.isSupported,
            voice: voice,
            voiceReason: voice ? nil : (transcriber?.unavailabilityReason ?? .unsupported))
    }
}

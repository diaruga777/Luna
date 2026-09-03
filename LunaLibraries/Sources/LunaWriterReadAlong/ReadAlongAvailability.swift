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

    /// True when voice is unavailable only because its permission has never
    /// been asked — distinct from a hard no (denied, unsupported, no
    /// on-device model). Unlike a hard no, asking can turn this into
    /// available, so a caller should still offer the toggle rather than hide
    /// it, and should call `resolve` again once the prompt returns.
    public var voiceIsUnasked: Bool { voiceReason == .permissionNotRequested }

    /// Asks the device and the transcriber. Nothing here is cached or
    /// resolved only once: a caller whose earlier `resolve` reported
    /// `voiceIsUnasked` (or whose permission state can otherwise have
    /// changed — a grant, a return from Settings, `didBecomeActive`) gets a
    /// current answer by calling this again, not by trusting the value from
    /// launch.
    public static func resolve(transcriber: SpeechTranscribing?) -> ReadAlongAvailability {
        let voice = transcriber?.isAvailable ?? false
        return ReadAlongAvailability(
            gaze: GazeTrackingAvailability.isSupported,
            voice: voice,
            voiceReason: voice ? nil : (transcriber?.unavailabilityReason ?? .unsupported))
    }
}

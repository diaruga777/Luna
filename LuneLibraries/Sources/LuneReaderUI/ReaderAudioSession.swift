//
//  ReaderAudioSession.swift
//  ReaderKit
//

import LuneStorage
import AVFoundation

/// The single choke-point for the read-aloud audio session. ONLY read-aloud
/// (`SpeechController`, RSVP speech mode) may activate it — the silent readers
/// must never call this. Every activation/deactivation is logged so any
/// unexpected interruption of other audio (e.g. Picture-in-Picture) is visible
/// in Settings → Diagnostics. Deactivation always notifies other apps so their
/// audio RESUMES rather than staying stopped.
public enum ReaderAudioSession {

    public static func activate() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
        SharedDiagnosticLog.record("audio session activated (.playback)", category: "audio")
    }

    public static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
        SharedDiagnosticLog.record("audio session deactivated", category: "audio")
    }
}

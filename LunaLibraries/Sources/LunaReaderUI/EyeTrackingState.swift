//
//  EyeTrackingState.swift
//  LunaReaderUI
//

import Foundation

/// The faces of the RSVP eye-tracking toggle: off, watching-but-idle,
/// watching-and-pausing, and temporarily unable to see a gaze.
public enum EyeTrackingDisplayState: Equatable {
    /// Not watching. Closed eyelid, grey.
    case disabled
    /// Watching, but nothing is playing for it to pause. Open eye, grey.
    case enabled
    /// Watching a live playback. Open eye, reading accent.
    case active
    /// The feature is enabled, but the camera has affirmatively lost the face
    /// or its gaze estimate. It has no effect until tracking recovers.
    case unavailable
}

/// Everything that decides whether the RSVP reader is currently watching the
/// reader's gaze, kept as a value type so the rules are testable away from
/// ARKit, UIKit, and playback.
///
/// Exactly one of the inputs is durable — `userEnabled`, mirrored into
/// `ReaderSettings.eyeTrackingEnabled`. The other state inputs are
/// deliberately transient, which is what makes the spec's "revert to what it
/// was before" behaviour fall out for free:
///
/// - `audioPlaybackOn` mirrors read-aloud. Eye tracking pauses a SILENT speed
///   read; with speech pacing the display, gaze has nothing to say. Turning
///   read-aloud back off restores whatever `userEnabled` was.
/// - `playOverridden` is set only when the user manually resumes after a
///   gaze-caused pause — an explicit "I know, keep going". It survives only
///   until playback is deliberately stopped again (or the process ends), at
///   which point the toggle returns to the user's own setting.
public struct EyeTrackingState: Equatable {

    /// The user's own on/off choice (persisted).
    public var userEnabled: Bool
    /// Transient force-disable from manually resuming after a gaze pause.
    public var playOverridden: Bool
    /// Read-aloud is on, so gaze pausing steps aside.
    public var audioPlaybackOn: Bool
    /// The RSVP reader is currently advancing words.
    public var isPlaying: Bool
    /// ARKit has affirmatively reported that it cannot produce a face/gaze
    /// estimate. This is deliberately distinct from the initial, unknown
    /// state: a session may simply not have delivered its first frame yet.
    public var gazeUnavailable: Bool

    public init(
        userEnabled: Bool = false, playOverridden: Bool = false,
        audioPlaybackOn: Bool = false, isPlaying: Bool = false,
        gazeUnavailable: Bool = false
    ) {
        self.userEnabled = userEnabled
        self.playOverridden = playOverridden
        self.audioPlaybackOn = audioPlaybackOn
        self.isPlaying = isPlaying
        self.gazeUnavailable = gazeUnavailable
    }

    /// Whether gaze should be watched at all right now.
    public var isWatching: Bool {
        userEnabled && !playOverridden && !audioPlaybackOn
    }

    public var displayState: EyeTrackingDisplayState {
        guard isWatching else { return .disabled }
        guard !gazeUnavailable else { return .unavailable }
        return isPlaying ? .active : .enabled
    }

    /// The toggle is inert while read-aloud owns playback: flipping it there
    /// would change `userEnabled` with no visible effect, so the button reads
    /// as disabled AND refuses the tap rather than lying about what it did.
    public var isToggleInteractive: Bool { !audioPlaybackOn }

    /// What a tap on the toggle should make happen. `.turnOn` is the only
    /// outcome that needs camera authorization.
    public enum ToggleIntent: Equatable { case turnOn, turnOff }

    /// The tap's intent, without applying it — a tap always moves between
    /// `.disabled` and (whichever of `.enabled`/`.active`/`.unavailable`
    /// tracking implies).
    public var toggleIntent: ToggleIntent {
        displayState == .disabled ? .turnOn : .turnOff
    }

    /// Applies a toggle. Turning ON also clears a play-override, so the one
    /// control the user reached for can always undo the force-disable it
    /// caused; turning OFF clears it too, so the stored preference and the
    /// suppression can never disagree about an OFF toggle.
    public mutating func applyToggle() {
        let intent = toggleIntent
        playOverridden = false
        userEnabled = intent == .turnOn
    }

    /// The user manually resumed after gaze paused playback: keep playing, and
    /// stand down until playback is deliberately stopped again.
    public mutating func overrideWithPlay() {
        playOverridden = true
    }

    /// Playback stopped by any route other than gaze — a manual pause, a link
    /// dive, leaving the reader, the end of the article. This is the "revert to
    /// what it was before" point for a play-override.
    public mutating func playbackStoppedDeliberately() {
        playOverridden = false
    }
}

//
//  ReadAlongState.swift
//  LunaWriterReadAlong
//

import Foundation
import LunaGaze

/// What the HUD's two dots say.
public enum ReadAlongIndicator: Equatable {
    /// The half is switched off, or the device cannot run it.
    case off
    /// Running and healthy.
    case ok
    /// Running, but the signal or the calibration is poor.
    case warn
    /// Deliberately held: paused tracking, or a permission still to answer.
    case busy
}

/// Everything that decides whether read-along is watching and listening.
///
/// Exactly two inputs are durable — `gazeEnabled` and `voiceEnabled`, mirrored
/// into `WriterSettings`. The rest are transient, so "revert to what it was
/// before" falls out of the process ending rather than from bookkeeping:
/// pausing tracking, losing a face and a mid-session permission refusal all
/// clear themselves.
public struct ReadAlongState: Equatable {

    /// The user's own gaze choice (persisted).
    public var gazeEnabled: Bool
    /// The user's own voice choice (persisted).
    public var voiceEnabled: Bool
    /// Tracking is held from the HUD's Pause item.
    public var isPaused: Bool
    /// ARKit has affirmatively lost the face or its gaze estimate.
    public var trackingLost: Bool
    /// The transcriber is capturing.
    public var isListening: Bool
    /// This device can run gaze at all.
    public var gazeAvailable: Bool
    /// This device and locale can run speech at all.
    public var voiceAvailable: Bool
    /// The last calibration's grade, or nil when none was ever made.
    public var calibrationGrade: CalibrationVerdict.Grade?

    public init(
        gazeEnabled: Bool = false,
        voiceEnabled: Bool = false,
        isPaused: Bool = false,
        trackingLost: Bool = false,
        isListening: Bool = false,
        gazeAvailable: Bool = true,
        voiceAvailable: Bool = true,
        calibrationGrade: CalibrationVerdict.Grade? = nil
    ) {
        self.gazeEnabled = gazeEnabled
        self.voiceEnabled = voiceEnabled
        self.isPaused = isPaused
        self.trackingLost = trackingLost
        self.isListening = isListening
        self.gazeAvailable = gazeAvailable
        self.voiceAvailable = voiceAvailable
        self.calibrationGrade = calibrationGrade
    }

    /// Whether gaze samples should be read into the reading model right now.
    public var isTracking: Bool {
        gazeEnabled && gazeAvailable && !isPaused
    }

    /// Whether speech should be captured right now.
    public var isVoiceActive: Bool {
        voiceEnabled && voiceAvailable
    }

    public var trackingIndicator: ReadAlongIndicator {
        guard gazeEnabled, gazeAvailable else { return .off }
        if isPaused { return .busy }
        if trackingLost { return .warn }
        if calibrationGrade == nil || calibrationGrade == .rough { return .warn }
        return .ok
    }

    public var micIndicator: ReadAlongIndicator {
        guard voiceEnabled, voiceAvailable else { return .off }
        return isListening ? .ok : .busy
    }

    /// A calibration is worth offering before tracking is trusted.
    public var needsCalibration: Bool {
        gazeEnabled && gazeAvailable && calibrationGrade == nil
    }

    /// Turning gaze on also clears the pause, so the one control the user
    /// reached for can undo the hold it caused.
    public mutating func applyGazeToggle() {
        let turningOn = !gazeEnabled
        isPaused = false
        trackingLost = false
        gazeEnabled = turningOn
    }

    public mutating func applyVoiceToggle() {
        let turningOn = !voiceEnabled
        voiceEnabled = turningOn
        if !turningOn { isListening = false }
    }

    /// Pausing keeps the user's gaze setting: resuming restores it.
    public mutating func applyPauseToggle() {
        isPaused.toggle()
        if isPaused { trackingLost = false }
    }
}

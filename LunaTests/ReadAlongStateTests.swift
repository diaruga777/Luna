//
//  ReadAlongStateTests.swift
//  LunaTests
//

import XCTest
@testable import LunaGaze
@testable import LunaWriterReadAlong

final class ReadAlongStateTests: XCTestCase {

    func testTrackingNeedsTheSettingTheHardwareAndNoPause() {
        var state = ReadAlongState(gazeEnabled: true, gazeAvailable: true)
        XCTAssertTrue(state.isTracking)

        state.isPaused = true
        XCTAssertFalse(state.isTracking)

        state.isPaused = false
        state.gazeAvailable = false
        XCTAssertFalse(state.isTracking)
    }

    func testPausingKeepsTheUsersSettingSoResumingRestoresIt() {
        var state = ReadAlongState(gazeEnabled: true, gazeAvailable: true)
        state.applyPauseToggle()
        XCTAssertTrue(state.gazeEnabled)
        XCTAssertFalse(state.isTracking)

        state.applyPauseToggle()
        XCTAssertTrue(state.isTracking)
    }

    func testTurningGazeOnClearsAPauseAndAStaleLostFace() {
        var state = ReadAlongState(
            gazeEnabled: false, isPaused: true, trackingLost: true, gazeAvailable: true)
        state.applyGazeToggle()
        XCTAssertTrue(state.gazeEnabled)
        XCTAssertFalse(state.isPaused)
        XCTAssertFalse(state.trackingLost)
        XCTAssertTrue(state.isTracking)
    }

    func testTurningVoiceOffStopsListening() {
        var state = ReadAlongState(voiceEnabled: true, isListening: true)
        state.applyVoiceToggle()
        XCTAssertFalse(state.voiceEnabled)
        XCTAssertFalse(state.isListening)
    }

    func testTheTrackingDotSeparatesOffPausedPoorAndHealthy() {
        var state = ReadAlongState(gazeEnabled: false, gazeAvailable: true)
        XCTAssertEqual(state.trackingIndicator, .off)

        state.gazeEnabled = true
        XCTAssertEqual(state.trackingIndicator, .warn, "no calibration yet is not healthy")

        state.calibrationGrade = .rough
        XCTAssertEqual(state.trackingIndicator, .warn)

        state.calibrationGrade = .usable
        XCTAssertEqual(state.trackingIndicator, .ok)

        state.trackingLost = true
        XCTAssertEqual(state.trackingIndicator, .warn)

        state.trackingLost = false
        state.isPaused = true
        XCTAssertEqual(state.trackingIndicator, .busy)
    }

    func testTheGazeDotIsOffWhereTheHardwareCannotRunIt() {
        let state = ReadAlongState(gazeEnabled: true, gazeAvailable: false)
        XCTAssertEqual(state.trackingIndicator, .off)
        XCTAssertFalse(state.isTracking)
    }

    func testTheMicDotSaysWhetherCaptureActuallyStarted() {
        var state = ReadAlongState(voiceEnabled: true, voiceAvailable: true)
        XCTAssertEqual(state.micIndicator, .busy)

        state.isListening = true
        XCTAssertEqual(state.micIndicator, .ok)

        state.voiceAvailable = false
        XCTAssertEqual(state.micIndicator, .off)
    }

    func testCalibrationIsOfferedOnlyWhileGazeIsOnAndUnfitted() {
        var state = ReadAlongState(gazeEnabled: true, gazeAvailable: true)
        XCTAssertTrue(state.needsCalibration)

        state.calibrationGrade = .rough
        XCTAssertFalse(state.needsCalibration, "a rough fit is a fit; the dot says the rest")

        state.calibrationGrade = nil
        state.gazeEnabled = false
        XCTAssertFalse(state.needsCalibration)
    }

    func testVoiceIsIndependentOfGaze() {
        let state = ReadAlongState(
            gazeEnabled: false, voiceEnabled: true, gazeAvailable: false, voiceAvailable: true)
        XCTAssertFalse(state.isTracking)
        XCTAssertTrue(state.isVoiceActive)
    }
}

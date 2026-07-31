//
//  EyeTrackingStateTests.swift
//  LunaTests
//
//  The RSVP eye-tracking toggle's three display states and the two transient
//  suppressions that produce them. See claudedocs/eye-tracking.md.
//

import LunaReaderUI
import XCTest

final class EyeTrackingStateTests: XCTestCase {

    // MARK: - Display states

    func testDefaultsToDisabled() {
        XCTAssertEqual(EyeTrackingState().displayState, .disabled)
    }

    func testEnabledWhilePausedAndActiveWhilePlaying() {
        var state = EyeTrackingState(userEnabled: true)
        XCTAssertEqual(state.displayState, .enabled)
        state.isPlaying = true
        XCTAssertEqual(state.displayState, .active,
                       "active is enabled + currently playing, nothing else")
    }

    func testActiveRequiresTheSettingAndNotJustPlayback() {
        let state = EyeTrackingState(userEnabled: false, isPlaying: true)
        XCTAssertEqual(state.displayState, .disabled)
    }

    func testUnavailableSignalOverridesActiveWithoutTurningTheSettingOff() {
        let state = EyeTrackingState(userEnabled: true, isPlaying: true, gazeUnavailable: true)
        XCTAssertEqual(state.displayState, .unavailable)
        XCTAssertTrue(state.userEnabled)
        XCTAssertTrue(state.isWatching,
                      "the camera should keep trying so the state can recover when eyes return")
    }

    // MARK: - Tapping

    func testTapEnablesFromDisabledAndDisablesFromEitherOtherState() {
        var state = EyeTrackingState()
        state.applyToggle()
        XCTAssertTrue(state.userEnabled)
        XCTAssertEqual(state.displayState, .enabled)

        state.isPlaying = true
        XCTAssertEqual(state.displayState, .active)
        state.applyToggle()
        XCTAssertEqual(state.displayState, .disabled,
                       "a tap from .active turns the feature off, same as from .enabled")
    }

    func testTapWhileForceDisabledTurnsTheFeatureBackOn() {
        var state = EyeTrackingState(userEnabled: true, isPlaying: true)
        state.overrideWithPlay()
        XCTAssertEqual(state.displayState, .disabled)

        state.applyToggle()
        XCTAssertFalse(state.playOverridden, "the toggle undoes the override it shows")
        XCTAssertEqual(state.displayState, .active)
    }

    // MARK: - Read-aloud

    func testReadAloudSuppressesTrackingAndRestoresItWhenTurnedOff() {
        var state = EyeTrackingState(userEnabled: true, isPlaying: true)
        state.audioPlaybackOn = true
        XCTAssertEqual(state.displayState, .disabled)
        XCTAssertFalse(state.isWatching)

        state.audioPlaybackOn = false
        XCTAssertEqual(state.displayState, .active,
                       "the user's own setting is untouched by read-aloud, so it comes back")
    }

    func testReadAloudDoesNotRestoreATrackerTheUserNeverEnabled() {
        var state = EyeTrackingState(userEnabled: false)
        state.audioPlaybackOn = true
        state.audioPlaybackOn = false
        XCTAssertEqual(state.displayState, .disabled)
    }

    func testToggleIsInertWhileReadAloudOwnsPlayback() {
        let state = EyeTrackingState(userEnabled: false, audioPlaybackOn: true)
        XCTAssertFalse(state.isToggleInteractive,
                       "flipping the setting under read-aloud would change nothing visible")
    }

    // MARK: - Play override

    func testPressingPlayWhileLookingAwayForceDisablesUntilPlaybackStops() {
        var state = EyeTrackingState(userEnabled: true, isPlaying: true)
        state.overrideWithPlay()
        XCTAssertFalse(state.isWatching)
        XCTAssertEqual(state.displayState, .disabled)
        XCTAssertTrue(state.userEnabled, "the durable setting is never rewritten")

        state.playbackStoppedDeliberately()
        XCTAssertEqual(state.displayState, .active,
                       "a manual pause reverts the force-disable to the user's setting")
    }

    func testOverrideDoesNotSurviveAsAStoredPreference() {
        var state = EyeTrackingState(userEnabled: true, isPlaying: true)
        state.overrideWithPlay()
        // `userEnabled` is the only value the reader persists; quitting the app
        // drops the rest, which is exactly the "revert on quit" rule.
        XCTAssertTrue(state.userEnabled)
        XCTAssertEqual(
            EyeTrackingState(userEnabled: state.userEnabled).displayState, .enabled,
            "a relaunch rebuilds from the stored setting alone")
    }
}

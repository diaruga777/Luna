//
//  RSVPPlaybackClockTests.swift
//  LunaTests
//
//  The words-mode word-timer shared by RSVPViewController and LinkRSVPPreview
//  — neither had a direct test of the schedule/rescale math before this was
//  extracted. `now` is injected so rescale math is deterministic without
//  waiting on real timers.
//

import LunaReaderUI
import XCTest

private final class RecordingDelegate: RSVPPlaybackClockDelegate {
    var fireCount = 0
    func playbackClockDidFire(_ clock: RSVPPlaybackClock) {
        fireCount += 1
    }
}

final class RSVPPlaybackClockTests: XCTestCase {
    func testScheduleMarksClockAsScheduledWithRequestedDuration() {
        let clock = RSVPPlaybackClock(now: { Date() })
        XCTAssertFalse(clock.isScheduled)
        clock.schedule(10)
        XCTAssertTrue(clock.isScheduled)
        XCTAssertEqual(clock.scheduledDuration, 10)
    }

    func testCancelClearsScheduledState() {
        let clock = RSVPPlaybackClock(now: { Date() })
        clock.schedule(10)
        clock.cancel()
        XCTAssertFalse(clock.isScheduled)
        XCTAssertNil(clock.scheduledDuration)
    }

    func testRescaleRemainingIsNoOpWhenNothingScheduled() {
        let clock = RSVPPlaybackClock(now: { Date() })
        clock.rescaleRemaining(by: 2)
        XCTAssertFalse(clock.isScheduled)
    }

    /// Doubling mid-flight (the reader's press-and-hold slow-motion) halves
    /// how much time has passed relative to what's rescaled: 2s remaining of
    /// a 4s interval, doubled, reschedules 4s remaining.
    func testRescaleRemainingDoublesTheOutstandingTime() {
        var now = Date(timeIntervalSince1970: 0)
        let clock = RSVPPlaybackClock(now: { now })
        clock.schedule(4)
        now = now.addingTimeInterval(2) // 2s elapsed, 2s remaining
        clock.rescaleRemaining(by: 2)
        XCTAssertEqual(clock.scheduledDuration!, 4, accuracy: 0.001)
    }

    /// Halving mid-flight (releasing the hold) restores the original pace:
    /// after the double-then-halve round trip the remaining time matches what
    /// it would have been at normal speed.
    func testRescaleRemainingHalvingUndoesADoubling() {
        var now = Date(timeIntervalSince1970: 0)
        let clock = RSVPPlaybackClock(now: { now })
        clock.schedule(4)
        now = now.addingTimeInterval(2) // 2s remaining
        clock.rescaleRemaining(by: 2) // now scheduled for 4s more
        clock.rescaleRemaining(by: 0.5) // immediately halved back
        XCTAssertEqual(clock.scheduledDuration!, 2, accuracy: 0.001)
    }

    /// Matches the preview's `applyTemporaryWPM` formula exactly: rescaling
    /// by `oldWPM / newWPM` is equivalent to its
    /// `oldDuration * (oldWPM / newWPM) * remainingFraction` computation.
    func testRescaleRemainingMatchesWPMRatioFormula() {
        var now = Date(timeIntervalSince1970: 0)
        let clock = RSVPPlaybackClock(now: { now })
        let oldDuration: TimeInterval = 0.5 // 300 wpm plain short word
        clock.schedule(oldDuration)
        now = now.addingTimeInterval(0.2) // 0.3s remaining, 40% elapsed
        let oldWPM = 300.0, newWPM = 450.0
        clock.rescaleRemaining(by: oldWPM / newWPM)

        let remainingFraction = 1 - 0.2 / oldDuration
        let expected = oldDuration * (oldWPM / newWPM) * remainingFraction
        XCTAssertEqual(clock.scheduledDuration!, expected, accuracy: 0.0001)
    }

    /// Never rescales to a negative remaining time even if `now` somehow
    /// reports more elapsed time than the interval's own length.
    func testRescaleRemainingClampsToZeroWhenOverElapsed() {
        var now = Date(timeIntervalSince1970: 0)
        let clock = RSVPPlaybackClock(now: { now })
        clock.schedule(1)
        now = now.addingTimeInterval(5)
        clock.rescaleRemaining(by: 2)
        XCTAssertEqual(clock.scheduledDuration!, 0, accuracy: 0.0001)
    }

    func testDelegateFiresAfterScheduledInterval() {
        let clock = RSVPPlaybackClock()
        let delegate = RecordingDelegate()
        clock.delegate = delegate
        let expectation = expectation(description: "fired")
        clock.schedule(0.05)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(delegate.fireCount, 1)
        XCTAssertFalse(clock.isScheduled, "the clock clears its own scheduled state once it fires")
    }

    func testReschedulingCancelsThePreviousInterval() {
        let clock = RSVPPlaybackClock()
        let delegate = RecordingDelegate()
        clock.delegate = delegate
        clock.schedule(0.05)
        clock.schedule(1) // replaces the short interval before it can fire
        let expectation = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(delegate.fireCount, 0, "the replaced interval must never fire")
    }
}

//
//  GazeAttentionTests.swift
//  LunaTests
//
//  The distance-dependent dwell tolerance and the allowance the RSVP reader
//  spends before a glance becomes a pause.
//

import LunaReaderUI
import UIKit
import XCTest
@testable import LunaGaze

final class GazeAttentionTests: XCTestCase {

    private let policy = GazeAttentionPolicy()
    private let focus = CGPoint(x: 160, y: 300)

    // MARK: - Policy

    func testGazeOnTheWordIsNeverTimed() {
        XCTAssertEqual(policy.tolerance(forDistance: 0), .infinity)
        XCTAssertEqual(policy.tolerance(forDistance: policy.focusRadius - 1), .infinity,
                       "the threshold around the focused word is generous on purpose")
    }

    func testToleranceShrinksWithDistance() {
        let near = policy.tolerance(forDistance: policy.focusRadius + 1)
        let middle = policy.tolerance(forDistance: policy.focusRadius + policy.falloffDistance / 2)
        let far = policy.tolerance(forDistance: policy.focusRadius + policy.falloffDistance)

        XCTAssertGreaterThan(near, middle)
        XCTAssertGreaterThan(middle, far)
        XCTAssertEqual(near, policy.nearTolerance, accuracy: 0.01)
        XCTAssertEqual(far, policy.farTolerance, accuracy: 0.001)
    }

    func testToleranceBottomsOutRatherThanGoingNegative() {
        XCTAssertEqual(policy.tolerance(forDistance: 10_000), policy.farTolerance, accuracy: 0.001)
    }

    func testLookingPastTheScreenGetsTheShortestFuseButALostFaceDoesNotPause() {
        XCTAssertEqual(policy.tolerance(for: .offScreen, focus: focus), policy.farTolerance)
        XCTAssertEqual(policy.tolerance(for: .faceLost, focus: focus), .infinity,
                       "a lost face is uncertainty, so it must never pause reading")
    }

    // MARK: - Monitor

    /// Feeds samples every `step` seconds and returns when the pause fired.
    private func timeToPause(
        _ sample: GazeSample, step: TimeInterval = 0.05, limit: TimeInterval = 10
    ) -> TimeInterval? {
        var monitor = GazeAttentionMonitor(policy: policy)
        var now: TimeInterval = 100
        monitor.update(sample: sample, focus: focus, at: now)
        while now < 100 + limit {
            now += step
            if monitor.update(sample: sample, focus: focus, at: now) { return now - 100 }
        }
        return nil
    }

    func testABriefGlanceDoesNotPause() {
        var monitor = GazeAttentionMonitor(policy: policy)
        let glance = GazeSample.point(CGPoint(x: focus.x, y: focus.y + policy.focusRadius + 40))
        monitor.update(sample: glance, focus: focus, at: 100)
        XCTAssertFalse(monitor.update(sample: glance, focus: focus, at: 100.2))
        XCTAssertTrue(monitor.isAway)
    }

    func testLookingAwayLongerPausesAndFartherPausesSooner() throws {
        let justOutside = GazeSample.point(
            CGPoint(x: focus.x, y: focus.y + policy.focusRadius + 20))
        let farAway = GazeSample.point(
            CGPoint(x: focus.x, y: focus.y + policy.focusRadius + policy.falloffDistance))

        let nearDelay = try XCTUnwrap(timeToPause(justOutside))
        let farDelay = try XCTUnwrap(timeToPause(farAway))
        let offScreenDelay = try XCTUnwrap(timeToPause(.offScreen))

        XCTAssertGreaterThan(nearDelay, farDelay,
                             "the delay depends on how far the gaze travelled")
        XCTAssertEqual(farDelay, offScreenDelay, accuracy: 0.06)
        XCTAssertEqual(nearDelay, policy.nearTolerance, accuracy: 0.1)
    }

    func testReturningToTheWordSpendsNothing() {
        var monitor = GazeAttentionMonitor(policy: policy)
        let away = GazeSample.point(CGPoint(x: focus.x, y: focus.y + 600))
        var now: TimeInterval = 100
        // Repeated flicks away, each shorter than the far tolerance, with the
        // gaze landing back on the word in between.
        for _ in 0..<20 {
            now += 0.1
            XCTAssertFalse(monitor.update(sample: away, focus: focus, at: now))
            now += 0.1
            XCTAssertFalse(monitor.update(sample: .point(focus), focus: focus, at: now))
        }
        XCTAssertFalse(monitor.isAway)
        XCTAssertEqual(monitor.awayProgress, 0, accuracy: 0.0001)
    }

    func testDriftingOutwardSpendsTheAllowanceAtEachInstantsRate() throws {
        var monitor = GazeAttentionMonitor(policy: policy)
        var now: TimeInterval = 100
        monitor.update(
            sample: .point(CGPoint(x: focus.x, y: focus.y + policy.focusRadius + 20)),
            focus: focus, at: now)
        // Half a second just outside the radius: a long way from tripping on its own.
        for _ in 0..<10 {
            now += 0.05
            XCTAssertFalse(monitor.update(
                sample: .point(CGPoint(x: focus.x, y: focus.y + policy.focusRadius + 20)),
                focus: focus, at: now))
        }
        let spentNearby = monitor.awayProgress
        XCTAssertGreaterThan(spentNearby, 0)

        // The gaze then leaves the phone: the rest of the allowance goes fast,
        // and the time already spent nearby still counts toward it.
        var elapsedOffScreen: TimeInterval = 0
        while elapsedOffScreen < 1 {
            now += 0.05
            elapsedOffScreen += 0.05
            if monitor.update(sample: .offScreen, focus: focus, at: now) { break }
        }
        XCTAssertLessThan(elapsedOffScreen, policy.farTolerance,
                          "time already spent looking away is not forgotten")
    }

    func testAStalledSessionDoesNotTripOnResume() {
        var monitor = GazeAttentionMonitor(policy: policy)
        monitor.update(sample: .offScreen, focus: focus, at: 100)
        XCTAssertFalse(monitor.update(sample: .offScreen, focus: focus, at: 400),
                       "a five-minute suspension must not read as five minutes of looking away")
    }

    func testResettingTheAllowanceKeepsWhereTheReaderIsLooking() {
        var monitor = GazeAttentionMonitor(policy: policy)
        monitor.update(sample: .offScreen, focus: focus, at: 100)
        monitor.update(sample: .offScreen, focus: focus, at: 100.2)
        monitor.resetAllowance()
        XCTAssertEqual(monitor.awayProgress, 0)
        XCTAssertTrue(monitor.isAway,
                      "a gaze pause resets the clock, not the reader's actual gaze — "
                      + "pressing play right after is still an override")

        monitor.clear()
        XCTAssertFalse(monitor.isAway)
    }
}

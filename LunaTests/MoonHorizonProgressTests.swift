//
//  MoonHorizonProgressTests.swift
//  LunaTests
//
//  The moon-horizon bar's traveling activity pulse: the chase that carries it
//  from the left edge into the sun.
//

@testable import LunaDesignSystem
import UIKit
import XCTest

final class MoonHorizonProgressTests: XCTestCase {

    private let step: TimeInterval = 1.0 / 60

    /// Runs one pulse against a head that starts at `headAtLaunch` and advances
    /// by `headSpeed` fractions of the bar per second — the same loop
    /// `MoonHorizonProgressBar` runs per display-link frame, minus the drawing.
    /// Returns where and when the two met.
    private func chase(
        headAtLaunch: CGFloat, headSpeed: CGFloat = 0
    ) -> (age: TimeInterval, meetingFraction: CGFloat)? {
        var pulse = MoonHorizonPulseChase()
        while pulse.age < MoonHorizonStyle.pulseMaximumLifetime {
            pulse.advance(by: step)
            let head = min(1, headAtLaunch + headSpeed * CGFloat(pulse.age))
            if pulse.fraction >= head { return (pulse.age, head) }
        }
        return nil
    }

    /// The pulse's speed is a function of how long it has been alive, not of how
    /// far it has left to go. That is what lets it close a gap that is itself
    /// still widening.
    func testSpeedGrowsWithAgeAlone() throws {
        var pulse = MoonHorizonPulseChase()
        XCTAssertEqual(pulse.speed, MoonHorizonStyle.pulseBaseSpeed, accuracy: 0.0001)

        var speeds: [CGFloat] = []
        for _ in 0..<60 {
            pulse.advance(by: step)
            speeds.append(pulse.speed)
        }
        XCTAssertTrue(
            zip(speeds, speeds.dropFirst()).allSatisfy { $1 > $0 },
            "the pulse never stops accelerating while it travels")
        XCTAssertGreaterThan(
            try XCTUnwrap(speeds.last) / MoonHorizonStyle.pulseBaseSpeed, 3,
            "and the acceleration is felt — a second in, it is several times faster")
    }

    /// Distance is covered progressively rather than saved up for the end: no
    /// single frame is allowed to be the journey.
    func testTravelHasNoSingleDominantLeap() throws {
        var pulse = MoonHorizonPulseChase()
        var jumps: [CGFloat] = []
        var previous: CGFloat = 0
        while pulse.fraction < 0.5, pulse.age < MoonHorizonStyle.pulseMaximumLifetime {
            pulse.advance(by: step)
            jumps.append(pulse.fraction - previous)
            previous = pulse.fraction
        }
        let largest = try XCTUnwrap(jumps.max())
        XCTAssertLessThan(
            largest, 0.05,
            "a frame covering a twentieth of the bar reads as a teleport, not motion")
    }

    /// Against a bar whose fraction is standing still, the travel keeps the pace
    /// the design asks for: about `pulseTravelDuration` across half the bar,
    /// less across a short stretch, more across a long one.
    func testStationaryHeadIsCaughtAtTheIntendedPace() throws {
        let half = try XCTUnwrap(chase(headAtLaunch: 0.5))
        XCTAssertEqual(half.age, MoonHorizonStyle.pulseTravelDuration, accuracy: 0.15)

        let short = try XCTUnwrap(chase(headAtLaunch: 0.2))
        let long = try XCTUnwrap(chase(headAtLaunch: 0.9))
        XCTAssertLessThan(short.age, half.age)
        XCTAssertGreaterThan(long.age, half.age)
        XCTAssertLessThan(long.age, 2, "even end to end it stays a beat, not a journey")
    }

    /// The regression this replaced: a pulse aimed at where the head was when it
    /// launched arrives short of a head that has since moved on, and the merge
    /// has to cover the difference in whatever time is left — which is no time
    /// at all. Chasing the live head means the two actually meet, at a point
    /// well past the launch snapshot.
    func testCatchesAHeadThatKeepsAdvancing() throws {
        let launch: CGFloat = 0.3
        let met = try XCTUnwrap(
            chase(headAtLaunch: launch, headSpeed: 0.25),
            "an accelerating pulse must always run down a head bounded at 1")
        XCTAssertGreaterThan(
            met.meetingFraction, launch + 0.2,
            "they meet where the head has got to, not where it was")
        XCTAssertLessThan(met.age, 2, "and it takes a beat longer, not an age")
    }

    /// Even a head sprinting to the end of the bar is run down inside the
    /// pulse's lifetime, so the backstop never has to fire.
    func testCatchesEvenTheFastestPossibleHead() throws {
        let met = try XCTUnwrap(chase(headAtLaunch: 0.06, headSpeed: 1))
        XCTAssertLessThan(met.age, MoonHorizonStyle.pulseMaximumLifetime)
        XCTAssertLessThanOrEqual(met.meetingFraction, 1)
    }

    /// The pulse never runs off the end of the bar.
    func testFractionIsClampedToTheBar() {
        var pulse = MoonHorizonPulseChase()
        for _ in 0..<600 { pulse.advance(by: step) }
        XCTAssertEqual(pulse.fraction, 1)
    }

    // MARK: - The bar itself

    /// Playback surfaces turn the pulse off; download surfaces leave it on.
    func testActivityPulseDefaultsOnAndCanBeDisabled() {
        let bar = MoonHorizonProgressBar()
        XCTAssertTrue(bar.showsActivityPulse)
        bar.showsActivityPulse = false
        XCTAssertFalse(bar.showsActivityPulse)
    }

    /// Progress is clamped and reported to VoiceOver as a percentage.
    func testSetProgressClampsAndAnnounces() {
        let bar = MoonHorizonProgressBar()
        bar.frame = CGRect(x: 0, y: 0, width: 200, height: 20)
        bar.setProgress(0.25, animated: false)
        XCTAssertEqual(bar.progress, 0.25, accuracy: 0.0001)
        XCTAssertEqual(bar.accessibilityValue, "25%")

        bar.setProgress(1.7, animated: false)
        XCTAssertEqual(bar.progress, 1)
        bar.setProgress(-0.3, animated: false)
        XCTAssertEqual(bar.progress, 0)
    }
}

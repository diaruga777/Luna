//
//  HorizonSpinnerViewTests.swift
//  LunaTests
//
//  API-contract coverage for Luna's shared horizon activity indicator.
//

import LunaDesignSystem
import UIKit
import XCTest

final class HorizonSpinnerViewTests: XCTestCase {

    /// The spinner's layer tree: a track ring, then one orbit container holding
    /// the pulse's frame of reference, the head's bloom and core, and the flare.
    private func layers(
        of spinner: HorizonSpinnerView
    ) throws -> (track: CAShapeLayer, orbit: CALayer, lights: [CALayer]) {
        let sublayers = try XCTUnwrap(spinner.layer.sublayers)
        XCTAssertEqual(sublayers.count, 2, "a track ring plus the orbit container")
        let track = try XCTUnwrap(sublayers.first as? CAShapeLayer)
        let orbit = try XCTUnwrap(sublayers.last)
        let lights = try XCTUnwrap(orbit.sublayers)
        XCTAssertEqual(lights.count, 4, "pulse orbit, head bloom, head core, merge flare")
        return (track, orbit, lights)
    }

    private func laidOutSpinner(side: CGFloat) -> HorizonSpinnerView {
        let spinner = HorizonSpinnerView(side: side)
        spinner.frame = CGRect(x: 0, y: 0, width: side, height: side)
        spinner.layoutIfNeeded()
        return spinner
    }

    /// The intrinsic size matches the configured side length (so `sizeToFit()` and
    /// Auto Layout both place it like the activity indicator it replaced).
    func testIntrinsicContentSizeMatchesConfiguredSide() {
        XCTAssertEqual(
            HorizonSpinnerView(side: 26).intrinsicContentSize, CGSize(width: 26, height: 26))
        XCTAssertEqual(
            HorizonSpinnerView(side: 36).intrinsicContentSize, CGSize(width: 36, height: 36))
    }

    /// The ring is a stroked path and the orbiting lights are its own layers, so
    /// all the motion stays in Core Animation.
    func testBuildsTrackAndOrbitLayers() throws {
        let parts = try layers(of: laidOutSpinner(side: 26))
        XCTAssertNotNil(parts.track.path)
        XCTAssertNil(parts.track.fillColor, "the track is stroked, never filled")
        XCTAssertGreaterThan(parts.track.lineWidth, 0)
    }

    /// The bloom spills outside the ring by design, so the view must never clip.
    func testDoesNotClipItsBloom() {
        XCTAssertFalse(HorizonSpinnerView(side: 26).clipsToBounds)
    }

    /// The head scales with the view: a small spinner gets a small point, not a
    /// fixed one that swamps its ring.
    func testHeadScalesWithTheView() throws {
        let small = try layers(of: laidOutSpinner(side: 20)).lights[2].bounds.width
        let large = try layers(of: laidOutSpinner(side: 40)).lights[2].bounds.width
        XCTAssertGreaterThan(small, 0)
        XCTAssertGreaterThan(large, small)
        XCTAssertLessThan(large, 20, "the core stays a point, never a disc")
    }

    /// `hidesWhenStopped` defaults to true: hidden at rest, visible while animating,
    /// hidden again after `stopAnimating()`.
    func testHidesWhenStoppedLifecycle() {
        let spinner = HorizonSpinnerView()
        XCTAssertTrue(spinner.hidesWhenStopped)
        XCTAssertTrue(spinner.isHidden)
        XCTAssertFalse(spinner.isAnimating)

        spinner.startAnimating()
        XCTAssertTrue(spinner.isAnimating)
        XCTAssertFalse(spinner.isHidden)

        spinner.stopAnimating()
        XCTAssertFalse(spinner.isAnimating)
        XCTAssertTrue(spinner.isHidden)
    }

    /// With `hidesWhenStopped == false`, the view stays visible when stopped.
    func testStaysVisibleWhenHidesWhenStoppedIsFalse() {
        let spinner = HorizonSpinnerView()
        spinner.hidesWhenStopped = false
        XCTAssertFalse(spinner.isHidden)
        spinner.startAnimating()
        spinner.stopAnimating()
        XCTAssertFalse(spinner.isHidden)
    }

    /// In a window, animating attaches the head's orbit, the pulse's own cycle,
    /// and the merge flare; stopping takes all three back off.
    func testAnimatingAttachesOrbitPulseAndFlare() throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "no motion to assert")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let spinner = laidOutSpinner(side: 36)
        window.addSubview(spinner)
        window.isHidden = false
        spinner.layoutIfNeeded()
        spinner.startAnimating()

        let parts = try layers(of: spinner)
        let animated = [parts.orbit, parts.lights[0], parts.lights[3]]
        for layer in animated {
            XCTAssertNotNil(layer.animationKeys()?.first)
        }
        spinner.stopAnimating()
        for layer in animated {
            XCTAssertNil(layer.animationKeys()?.first)
        }
    }

    /// The head's orbit is a keyframe animation precisely because its speed is
    /// not constant: it must sweep a full turn per lap while varying its pace,
    /// and it must repeat forever.
    func testHeadOrbitSweepsAFullLapAtAVaryingPace() throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "no motion to assert")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let spinner = laidOutSpinner(side: 36)
        window.addSubview(spinner)
        window.isHidden = false
        spinner.startAnimating()

        let orbit = try layers(of: spinner).orbit
        let key = try XCTUnwrap(orbit.animationKeys()?.first)
        let animation = try XCTUnwrap(orbit.animation(forKey: key) as? CAKeyframeAnimation)
        XCTAssertEqual(animation.repeatCount, .infinity)
        let angles = try XCTUnwrap(animation.values as? [NSNumber]).map { CGFloat($0.doubleValue) }
        XCTAssertEqual(angles.first, 0)
        XCTAssertEqual(try XCTUnwrap(angles.last), .pi * 2, accuracy: 0.0001)
        // Strictly increasing (it never stalls or backs up)…
        let steps = zip(angles, angles.dropFirst()).map { $1 - $0 }
        XCTAssertTrue(steps.allSatisfy { $0 > 0 }, "the head never stalls")
        // …but decidedly uneven: the fastest stretch outpaces the slowest.
        let fastest = try XCTUnwrap(steps.max())
        let slowest = try XCTUnwrap(steps.min())
        XCTAssertGreaterThan(fastest / slowest, 2, "the pace visibly swells and eases")
        let speedChanges = zip(steps, steps.dropFirst()).map { $1 - $0 }
            .filter { abs($0) > 0.000001 }
        let slowBeats = zip(speedChanges, speedChanges.dropFirst()).filter { $0 < 0 && $1 > 0 }
        XCTAssertEqual(slowBeats.count, 1, "one broad speed swell per lap")
        XCTAssertGreaterThanOrEqual(animation.duration, 3, "the speed changes have room to breathe")
    }

    /// The pulse laps the ring *relative to the head* — a full turn within the
    /// head's own rotating frame — so it departs from and returns to exactly
    /// where the head is, and rests (invisible) until its next cycle.
    func testPulseTakesOneRelativeLapThenRests() throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "no motion to assert")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let spinner = laidOutSpinner(side: 36)
        window.addSubview(spinner)
        window.isHidden = false
        spinner.startAnimating()

        let pulse = try layers(of: spinner).lights[0]
        let key = try XCTUnwrap(pulse.animationKeys()?.first)
        let group = try XCTUnwrap(pulse.animation(forKey: key) as? CAAnimationGroup)
        XCTAssertEqual(group.repeatCount, .infinity)
        let animations = try XCTUnwrap(group.animations) as? [CAKeyframeAnimation]
        let parts = try XCTUnwrap(animations)
        XCTAssertEqual(parts.count, 2, "a sweep and its fade")
        for part in parts {
            XCTAssertEqual(
                part.duration, group.duration,
                "a grouped animation left at the default duration snaps instead of playing")
        }

        let sweep = try XCTUnwrap(parts.first { $0.keyPath == "transform.rotation.z" })
        let angles = try XCTUnwrap(sweep.values as? [NSNumber]).map { CGFloat($0.doubleValue) }
        XCTAssertEqual(angles.first, 0)
        XCTAssertEqual(try XCTUnwrap(angles.last), .pi * 2, accuracy: 0.0001)
        // The travel ends before the cycle does — the rest of it is the rest.
        let travelEnd = try XCTUnwrap(sweep.keyTimes?.dropLast().last).doubleValue
        XCTAssertLessThan(travelEnd, 1)
        XCTAssertEqual(try XCTUnwrap(sweep.keyTimes?.last).doubleValue, 1)

        let fade = try XCTUnwrap(parts.first { $0.keyPath == "opacity" })
        XCTAssertEqual(fade.values?.first as? Int, 0, "invisible at the moment it separates")
        XCTAssertEqual(fade.values?.last as? Int, 0, "and invisible again while it rests")
    }

    /// The flare must peak when the smaller dot reaches the head. Easing the
    /// flare's whole group used to pull that peak forward in real time, even
    /// though the individual keyframes appeared close to the merge.
    func testFlarePeaksAtCatchUpOnTheSameClock() throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "no motion to assert")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let spinner = laidOutSpinner(side: 36)
        window.addSubview(spinner)
        window.isHidden = false
        spinner.startAnimating()
        defer { spinner.stopAnimating() }

        let lights = try layers(of: spinner).lights
        let pulse = try XCTUnwrap(
            lights[0].animation(forKey: "horizonPulseCycle") as? CAAnimationGroup)
        let flare = try XCTUnwrap(
            lights[3].animation(forKey: "horizonMergeFlare") as? CAAnimationGroup)
        XCTAssertEqual(pulse.beginTime, flare.beginTime)
        XCTAssertEqual(pulse.duration, flare.duration)
        XCTAssertGreaterThanOrEqual(pulse.duration, 5.5, "catch-ups should not feel too frequent")
        for group in [pulse, flare] {
            let timing = try XCTUnwrap(group.timingFunction)
            for index in 1...2 {
                var point: [Float] = [0, 0]
                timing.getControlPoint(at: index, values: &point)
                XCTAssertEqual(point[0], point[1], accuracy: 0.0001,
                               "group easing must not shift the merge or brightness peak")
            }
        }

        let pulseAnimations = try XCTUnwrap(pulse.animations as? [CAKeyframeAnimation])
        let sweep = try XCTUnwrap(pulseAnimations.first { $0.keyPath == "transform.rotation.z" })
        let merge = try XCTUnwrap(sweep.keyTimes?.dropLast().last).doubleValue
        XCTAssertGreaterThanOrEqual(merge * pulse.duration, 3.5, "a longer catch-up sweep")
        XCTAssertEqual(sweep.calculationMode, .linear, "no overshoot when the dots merge")
        let fade = try XCTUnwrap(pulseAnimations.first { $0.keyPath == "opacity" })
        let fadeTimes = try XCTUnwrap(fade.keyTimes)
        let fadeStart = fadeTimes[2].doubleValue
        XCTAssertLessThan((merge - fadeStart) * pulse.duration, 0.15,
                          "keep the smaller dot visible until the final approach")
        XCTAssertEqual(fadeTimes[3].doubleValue, merge, accuracy: 0.0001)

        let flareAnimations = try XCTUnwrap(flare.animations as? [CAKeyframeAnimation])
        let flash = try XCTUnwrap(flareAnimations.first { $0.keyPath == "opacity" })
        let brightness = try XCTUnwrap(flash.values as? [NSNumber]).map(\.doubleValue)
        let peak = try XCTUnwrap(brightness.indices.max { brightness[$0] < brightness[$1] })
        let peakTime = try XCTUnwrap(flash.keyTimes?[peak]).doubleValue
        XCTAssertEqual(peakTime, merge, accuracy: 0.0001,
                       "maximum brightness coincides with the completed relative lap")
        XCTAssertEqual(flash.duration, pulse.duration)
    }

    /// `resolveToCheckmark` only runs its success beat while animating; stopped,
    /// it calls back immediately and adds nothing.
    func testResolveToCheckmarkWhenStoppedCallsBackImmediately() {
        let spinner = laidOutSpinner(side: 40)
        let layerCount = spinner.layer.sublayers?.count ?? 0
        var resolved = false
        spinner.resolveToCheckmark { resolved = true }
        XCTAssertTrue(resolved)
        XCTAssertEqual(spinner.layer.sublayers?.count ?? 0, layerCount)
    }

    /// While animating it stops the orbit and adds the checkmark stroke.
    func testResolveToCheckmarkDrawsCheck() throws {
        let spinner = laidOutSpinner(side: 40)
        spinner.hidesWhenStopped = false
        spinner.startAnimating()

        let expectation = expectation(description: "resolved")
        spinner.resolveToCheckmark { expectation.fulfill() }
        XCTAssertFalse(spinner.isAnimating)
        let check = try XCTUnwrap(spinner.layer.sublayers?.last as? CAShapeLayer)
        XCTAssertNotNil(check.path)
        XCTAssertNil(check.fillColor, "the checkmark is stroked, never filled")
        wait(for: [expectation], timeout: 3)
    }
}

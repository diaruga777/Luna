//
//  RabbitHoleTransitionSettings.swift
//  Clip
//
//  Persisted, tunable parameters for the RabbitHole reader's two-phase pixel-mosaic
//  transition (the dive / pop / overscroll wipe). Stored in the App Group so the values
//  survive relaunch; read by `HalftoneRabbitHoleTransition` at play time.
//

import ClipStorage
import CoreGraphics
import Foundation

enum RabbitHoleTransitionSettings {

    // MARK: Slider ranges (each exposed across its full sensible range)

    /// Mosaic block size, in points — bigger = chunkier pixels.
    static let pixelSizeRange: ClosedRange<Double> = 6...64
    /// Phase 1 (existing view → pixelated final) duration, seconds.
    static let phase1DurationRange: ClosedRange<Double> = 0.1...2.0
    /// Phase 2 (pixelated final → final) duration, seconds.
    static let phase2DurationRange: ClosedRange<Double> = 0.05...1.5
    /// How spread-out the per-cell reveal is in phase 1: 0 = all cells flip together,
    /// 1 = fully one-at-a-time.
    static let staggerRange: ClosedRange<Double> = 0...1

    // MARK: Defaults

    private static let defaultPixelSize: Double = 24
    private static let defaultPhase1: Double = 0.55
    private static let defaultPhase2: Double = 0.35
    private static let defaultStagger: Double = 0.6
    private static let defaultMonochrome = false

    // MARK: Storage

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: ReadingListStore.appGroupID) ?? .standard
    }

    private static func double(_ key: String, _ fallback: Double, in range: ClosedRange<Double>) -> Double {
        let value = defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
        return min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: Properties

    static var pixelSize: CGFloat {
        get { CGFloat(double("rhTransitionPixelSize", defaultPixelSize, in: pixelSizeRange)) }
        set { defaults.set(Double(newValue), forKey: "rhTransitionPixelSize") }
    }

    static var phase1Duration: TimeInterval {
        get { double("rhTransitionPhase1", defaultPhase1, in: phase1DurationRange) }
        set { defaults.set(newValue, forKey: "rhTransitionPhase1") }
    }

    static var phase2Duration: TimeInterval {
        get { double("rhTransitionPhase2", defaultPhase2, in: phase2DurationRange) }
        set { defaults.set(newValue, forKey: "rhTransitionPhase2") }
    }

    static var stagger: CGFloat {
        get { CGFloat(double("rhTransitionStagger", defaultStagger, in: staggerRange)) }
        set { defaults.set(Double(newValue), forKey: "rhTransitionStagger") }
    }

    static var monochrome: Bool {
        get { defaults.object(forKey: "rhTransitionMono") == nil ? defaultMonochrome : defaults.bool(forKey: "rhTransitionMono") }
        set { defaults.set(newValue, forKey: "rhTransitionMono") }
    }

    // MARK: Derived

    /// Total wall-clock duration of the whole wipe (drives the non-interactive play and
    /// the interactive settle).
    static var totalDuration: TimeInterval { phase1Duration + phase2Duration }

    /// Where phase 1 ends along the 0…1 progress timeline, so the shader spends the
    /// phase durations proportionally.
    static var phaseSplit: CGFloat {
        let total = totalDuration
        return total > 0 ? CGFloat(phase1Duration / total) : 0.5
    }

    /// Reset every parameter to its default.
    static func resetToDefaults() {
        pixelSize = CGFloat(defaultPixelSize)
        phase1Duration = defaultPhase1
        phase2Duration = defaultPhase2
        stagger = CGFloat(defaultStagger)
        monochrome = defaultMonochrome
    }
}

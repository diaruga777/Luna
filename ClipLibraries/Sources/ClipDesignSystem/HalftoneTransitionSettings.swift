//
//  HalftoneTransitionSettings.swift
//  ClipDesignSystem
//
//  Persisted, tunable parameters for the halftone "pixel wipe" — the two-wavefront
//  pixel-mosaic dissolve used both by the RabbitHole reader (dive / pop / overscroll)
//  and by the global transitions (nav push/pop, modal present/dismiss, in-place
//  crossfades, table batch updates). Stored in the App Group so the values survive
//  relaunch and the action extension honors the same look. Lives in ClipDesignSystem
//  so the shared transition facade and the extension can read it.
//
//  The visual style (pixelSize / cornerRadius / spacing / monochrome) and the timing
//  feel (phase durations / stagger) are global; the wavefront *direction* is chosen
//  per transition by the caller and is not persisted here.
//

import CoreGraphics
import Foundation

public enum HalftoneTransitionSettings {

    // MARK: Slider ranges (each exposed across its full sensible range)

    /// Mosaic cell size, in points — bigger = chunkier dots.
    public static let pixelSizeRange: ClosedRange<Double> = 6...64
    /// Dot corner radius, in points.
    public static let cornerRadiusRange: ClosedRange<Double> = 0...8
    /// Gap between dots, in points.
    public static let spacingRange: ClosedRange<Double> = 0...8
    /// Wave 1 (existing view → pixelated dots) duration, seconds.
    public static let phase1DurationRange: ClosedRange<Double> = 0.1...2.0
    /// Wave 2 (pixelated dots → final view) duration, seconds.
    public static let phase2DurationRange: ClosedRange<Double> = 0.05...1.5
    /// How spread-out the per-cell reveal is within a wave: 0 = all cells flip
    /// together, 1 = fully one-at-a-time.
    public static let staggerRange: ClosedRange<Double> = 0...1

    // MARK: Defaults

    private static let defaultPixelSize: Double = 6
    private static let defaultCornerRadius: Double = 2
    private static let defaultSpacing: Double = 2
    private static let defaultPhase1: Double = 0.55
    private static let defaultPhase2: Double = 0.35
    private static let defaultStagger: Double = 0.6
    private static let defaultMonochrome = false

    // MARK: Storage (App Group, shared with the action extension)

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: ReaderSettings.appGroupID) ?? .standard
    }

    private static func double(_ key: String, _ fallback: Double, in range: ClosedRange<Double>) -> Double {
        let value = defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
        return min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: Properties

    public static var pixelSize: CGFloat {
        get { CGFloat(double("rhTransitionPixelSize", defaultPixelSize, in: pixelSizeRange)) }
        set { defaults.set(Double(newValue), forKey: "rhTransitionPixelSize") }
    }

    public static var cornerRadius: CGFloat {
        get { CGFloat(double("rhTransitionCornerRadius", defaultCornerRadius, in: cornerRadiusRange)) }
        set { defaults.set(Double(newValue), forKey: "rhTransitionCornerRadius") }
    }

    public static var spacing: CGFloat {
        get { CGFloat(double("rhTransitionSpacing", defaultSpacing, in: spacingRange)) }
        set { defaults.set(Double(newValue), forKey: "rhTransitionSpacing") }
    }

    public static var phase1Duration: TimeInterval {
        get { double("rhTransitionPhase1", defaultPhase1, in: phase1DurationRange) }
        set { defaults.set(newValue, forKey: "rhTransitionPhase1") }
    }

    public static var phase2Duration: TimeInterval {
        get { double("rhTransitionPhase2", defaultPhase2, in: phase2DurationRange) }
        set { defaults.set(newValue, forKey: "rhTransitionPhase2") }
    }

    public static var stagger: CGFloat {
        get { CGFloat(double("rhTransitionStagger", defaultStagger, in: staggerRange)) }
        set { defaults.set(Double(newValue), forKey: "rhTransitionStagger") }
    }

    public static var monochrome: Bool {
        get { defaults.object(forKey: "rhTransitionMono") == nil ? defaultMonochrome : defaults.bool(forKey: "rhTransitionMono") }
        set { defaults.set(newValue, forKey: "rhTransitionMono") }
    }

    // MARK: Derived

    /// Total wall-clock duration of the whole wipe (drives the non-interactive play and
    /// the interactive settle).
    public static var totalDuration: TimeInterval { phase1Duration + phase2Duration }

    /// Normalized delay (0…0.95) before wave 2 starts trailing wave 1 — the fraction of
    /// the timeline spent on phase 1 maps to how far apart the two fronts run.
    public static var lag: CGFloat {
        let total = totalDuration
        guard total > 0 else { return 0.35 }
        return CGFloat(min(max(phase1Duration / total, 0), 0.95))
    }

    /// Per-wave per-cell crossfade window (0.05…1). Mirrors the old `1 - stagger`
    /// relationship: 0 stagger → window 1 (cells animate together), 1 stagger → a tight,
    /// near one-at-a-time front.
    public static var window: CGFloat {
        CGFloat(min(max(1 - Double(stagger), 0.05), 1))
    }

    /// Reset every parameter to its default.
    public static func resetToDefaults() {
        pixelSize = CGFloat(defaultPixelSize)
        cornerRadius = CGFloat(defaultCornerRadius)
        spacing = CGFloat(defaultSpacing)
        phase1Duration = defaultPhase1
        phase2Duration = defaultPhase2
        stagger = CGFloat(defaultStagger)
        monochrome = defaultMonochrome
    }
}

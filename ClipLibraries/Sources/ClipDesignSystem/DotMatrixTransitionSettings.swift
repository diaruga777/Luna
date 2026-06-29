//
//  DotMatrixTransitionSettings.swift
//  ClipDesignSystem
//
//  Persisted, tunable parameters for the Dot Matrix "pixel wipe" — the two-wavefront
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

public enum DotMatrixTransitionSettings {

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
    private static let defaultSpacing: Double = 1
    private static let defaultPhase1: Double = 0.45
    private static let defaultPhase2: Double = 0.40
    private static let defaultStagger: Double = 0.2
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

    /// Spread of the wavefront across the screen (first-cell → last-cell arrival) as a
    /// fraction of the timeline. The DOMINANT component, so the transition reads as a
    /// moving front (directional) or scattered dots (random) — not a flat fade. Higher
    /// stagger = a more spread-out, sequential front.
    ///
    /// The 0.40 floor keeps the front pronounced even at low stagger: at the hardened
    /// default stagger (0.2) sweep ≈ 0.49 while `win` ≈ 0.26, so the moving front is
    /// roughly twice the per-cell fade and stays clearly dominant — no flat fade.
    public static var sweep: CGFloat {
        CGFloat(min(max(0.40 + Double(stagger) * 0.45, 0.20), 0.90))
    }

    /// Per-cell fade width — how long one cell takes to cross. Higher stagger = crisper
    /// (narrower) per-cell fade.
    public static var win: CGFloat {
        CGFloat(min(max(0.30 - Double(stagger) * 0.20, 0.06), 0.30))
    }

    /// How far wave 2 (sharpen) trails wave 1 (pixelate), kept below `sweep` so the
    /// sharpen front starts while the pixelation front is still sweeping. Phase 1's share
    /// of the total duration biases how far apart the two fronts run.
    public static var lag: CGFloat {
        let total = totalDuration
        let share = total > 0 ? phase1Duration / total : 0.5
        return sweep * CGFloat(min(max(share, 0.25), 0.70))
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

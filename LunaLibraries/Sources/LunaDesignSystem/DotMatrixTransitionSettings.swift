//
//  DotMatrixTransitionSettings.swift
//  LunaDesignSystem
//
//  Persisted, tunable parameters for the Dot Matrix "pixel wipe" — the two-wavefront
//  pixel-mosaic dissolve used both by the RabbitHole reader (dive / pop / overscroll)
//  and by the global transitions (nav push/pop, modal present/dismiss, in-place
//  crossfades, table batch updates). Stored in the App Group so the values survive
//  relaunch and the action extension honors the same look. Lives in LunaDesignSystem
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
    /// Wave 1 (existing view → pixelated dots) sweep duration, seconds — how long
    /// the pixelation front takes to cross the screen.
    public static let phase1DurationRange: ClosedRange<Double> = 0.1...2.0
    /// Wave 2 (pixelated dots → final view) sweep duration, seconds.
    public static let phase2DurationRange: ClosedRange<Double> = 0.05...1.5
    /// Wall-clock delay between wave 1 STARTING and wave 2 STARTING, seconds. Larger
    /// than the wave durations ⇒ the screen holds the fully-pixelated state between
    /// the two fronts; smaller ⇒ wave 2 starts while wave 1 is still sweeping.
    public static let interWaveDelayRange: ClosedRange<Double> = 0...1.0
    /// How spread-out the per-cell reveal is within a wave: 0 = all cells flip
    /// together, 1 = fully one-at-a-time.
    public static let staggerRange: ClosedRange<Double> = 0...1

    // MARK: Defaults

    private static let defaultPixelSize: Double = 6
    private static let defaultCornerRadius: Double = 2
    private static let defaultSpacing: Double = 1
    private static let defaultPhase1: Double = 0.1
    private static let defaultPhase2: Double = 0.1
    private static let defaultInterWaveDelay: Double = 0.2
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

    /// Wall-clock time between wave 1 starting and wave 2 starting.
    public static var interWaveDelay: TimeInterval {
        get { double("rhTransitionInterWaveDelay", defaultInterWaveDelay, in: interWaveDelayRange) }
        set { defaults.set(newValue, forKey: "rhTransitionInterWaveDelay") }
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

    // The shader (`RabbitHoleTransition.metal`) drives one global `progress` 0→1 over
    // `totalDuration` and internally normalises its timeline by `span = sweep+lag+win`,
    // so per-cell wall times are `(sweep/span)·total` (wave-1 front sweep),
    // `(lag/span)·total` (wave-1 → wave-2 start gap) and `(win/span)·total` (one cell's
    // fade). We therefore express `sweep`/`lag`/`win` as the actual wall-second budgets
    // NORMALISED to sum to 1 and set `totalDuration` to their sum — then each fraction,
    // multiplied back through, lands on its exact wall duration. So at the defaults the
    // wave-1 front sweeps in `phase1Duration` (0.1s), wave 2 starts `interWaveDelay`
    // (0.2s) after wave 1, and each cell's fade is short and crisp.

    /// Wall seconds the pixelation/sharpen FRONT takes to cross the screen. The shader
    /// uses a single sweep for both wavefronts, so both waves share this; the two phase
    /// sliders average into it.
    private static var sweepSeconds: TimeInterval { (phase1Duration + phase2Duration) / 2 }
    /// Wall seconds one cell takes to fade. Crisper (shorter) at higher stagger.
    private static var winSeconds: TimeInterval { sweepSeconds * (0.5 - 0.35 * Double(stagger)) }
    /// Wall seconds the whole timeline spans (first cell's wave-1 start → last cell's
    /// wave-2 end): the sweep, plus the inter-wave delay, plus one trailing cell fade.
    private static var spanSeconds: TimeInterval {
        max(sweepSeconds + interWaveDelay + winSeconds, 0.001)
    }

    /// Total wall-clock duration of the whole wipe (drives the non-interactive play and
    /// the interactive settle).
    public static var totalDuration: TimeInterval { spanSeconds }

    /// Spread of the wavefront across the screen (first-cell → last-cell arrival) as a
    /// fraction of the timeline: `sweepSeconds` normalised by the span.
    public static var sweep: CGFloat { CGFloat(sweepSeconds / spanSeconds) }

    /// Per-cell fade width — how long one cell takes to cross, as a fraction of the
    /// timeline.
    public static var win: CGFloat { CGFloat(winSeconds / spanSeconds) }

    /// How far wave 2 (sharpen) trails wave 1 (pixelate), as a fraction of the timeline:
    /// the inter-wave delay normalised by the span.
    public static var lag: CGFloat { CGFloat(interWaveDelay / spanSeconds) }

    /// Reset every parameter to its default.
    public static func resetToDefaults() {
        pixelSize = CGFloat(defaultPixelSize)
        cornerRadius = CGFloat(defaultCornerRadius)
        spacing = CGFloat(defaultSpacing)
        phase1Duration = defaultPhase1
        phase2Duration = defaultPhase2
        interWaveDelay = defaultInterWaveDelay
        stagger = CGFloat(defaultStagger)
        monochrome = defaultMonochrome
    }
}

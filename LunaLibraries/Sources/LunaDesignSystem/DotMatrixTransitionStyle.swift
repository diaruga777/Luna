//
//  DotMatrixTransitionStyle.swift
//  LunaDesignSystem
//
//  Fixed parameters for the Dot Matrix "pixel wipe" — the two-wavefront pixel-mosaic
//  dissolve used both by the RabbitHole reader (dive / pop / overscroll) and by the
//  global transitions (nav push/pop, modal present/dismiss, in-place crossfades, table
//  batch updates). Lives in LunaDesignSystem so the shared transition facade and the
//  action extension read one identical look.
//
//  The visual style (pixelSize / cornerRadius / spacing) and the timing feel (phase
//  durations / stagger) are global; the wavefront *direction* is chosen per transition
//  by the caller.
//

import CoreGraphics
import Foundation

public enum DotMatrixTransitionStyle {

    // MARK: Geometry

    /// Mosaic cell size, in points — bigger dots read chunkier.
    public static let pixelSize: CGFloat = 6
    /// Dot corner radius, in points.
    public static let cornerRadius: CGFloat = 2
    /// Gap between dots, in points.
    public static let spacing: CGFloat = 1

    // MARK: Timing

    /// Wave 1 (existing view → pixelated dots) sweep duration, seconds — how long the
    /// pixelation front takes to cross the screen.
    public static let phase1Duration: TimeInterval = 0.1
    /// Wave 2 (pixelated dots → final view) sweep duration, seconds.
    public static let phase2Duration: TimeInterval = 0.1
    /// Wall-clock delay between wave 1 STARTING and wave 2 STARTING, seconds. Larger than
    /// the wave durations, so the screen holds the fully-pixelated state between the two
    /// fronts.
    public static let interWaveDelay: TimeInterval = 0.2
    /// How spread-out the per-cell reveal is within a wave: 0 = all cells flip together,
    /// 1 = fully one-at-a-time.
    public static let stagger: CGFloat = 0.2

    // MARK: Derived

    // The shader (`RabbitHoleTransition.metal`) drives one global `progress` 0→1 over
    // `totalDuration` and internally normalises its timeline by `span = sweep+lag+win`,
    // so per-cell wall times are `(sweep/span)·total` (wave-1 front sweep),
    // `(lag/span)·total` (wave-1 → wave-2 start gap) and `(win/span)·total` (one cell's
    // fade). `sweep`/`lag`/`win` are therefore the actual wall-second budgets NORMALISED
    // to sum to 1, with `totalDuration` set to their sum — so each fraction, multiplied
    // back through, lands on its exact wall duration. The wave-1 front sweeps in 0.1s,
    // wave 2 starts 0.2s after wave 1, and each cell's fade is short and crisp.

    /// Wall seconds the pixelation/sharpen FRONT takes to cross the screen. The shader
    /// uses a single sweep for both wavefronts, so both waves share this; the two phase
    /// durations average into it.
    private static let sweepSeconds: TimeInterval = (phase1Duration + phase2Duration) / 2
    /// Wall seconds one cell takes to fade. Crisper (shorter) at higher stagger.
    private static let winSeconds: TimeInterval = sweepSeconds * (0.5 - 0.35 * Double(stagger))
    /// Wall seconds the whole timeline spans (first cell's wave-1 start → last cell's
    /// wave-2 end): the sweep, plus the inter-wave delay, plus one trailing cell fade.
    private static let spanSeconds: TimeInterval = max(sweepSeconds + interWaveDelay + winSeconds, 0.001)

    /// Total wall-clock duration of the whole wipe (drives the non-interactive play and
    /// the interactive settle).
    public static let totalDuration: TimeInterval = spanSeconds

    /// Spread of the wavefront across the screen (first-cell → last-cell arrival) as a
    /// fraction of the timeline: `sweepSeconds` normalised by the span.
    public static let sweep: CGFloat = CGFloat(sweepSeconds / spanSeconds)

    /// Per-cell fade width — how long one cell takes to cross, as a fraction of the
    /// timeline.
    public static let win: CGFloat = CGFloat(winSeconds / spanSeconds)

    /// How far wave 2 (sharpen) trails wave 1 (pixelate), as a fraction of the timeline:
    /// the inter-wave delay normalised by the span.
    public static let lag: CGFloat = CGFloat(interWaveDelay / spanSeconds)
}

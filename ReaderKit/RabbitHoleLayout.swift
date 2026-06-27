//
//  RabbitHoleLayout.swift
//  Clip
//
//  Forked, experimental "RabbitHole" reader — see RabbitHoleReaderViewController.
//

import UIKit

/// Pure geometry for the RabbitHole stacked-layer reader. Every layer's on-screen
/// frame is a function of a single continuous `focus` (the fractional stack index of
/// the focused layer) — so all motion (open / close / overscroll / interrupt) is just
/// `focus` moving, with one place computing frames. This is the generalization of
/// `SplitWebOverlayViewController.apply(progress:)` to an N-layer stack.
///
/// Model (let `δ = focus - layerIndex`, the layer's distance *behind* the focus):
/// - `δ == 0`  → the focused layer: most inset, fills the focused area, no lips.
/// - `δ == 1`  → the parent: one inset step out; a top lip, bottom lip, and leading
///               indent of its background peek around the focused layer.
/// - `δ == 2`  → the grandparent: two steps out (fills the screen behind everything),
///               its lips peek around the parent's.
/// - `δ  > 2`  → tucked fully offscreen past the leading edge (only ever the 3rd+
///               ancestor; restored as you climb back up).
/// - `δ  < 0`  → a layer being born (push) / dying (pop): emerges from a thin sliver
///               at the split line and grows to the focused frame.
///
/// At most two ancestors are ever visible at once: `visibleAncestors = min(2, focus)`.
struct RabbitHoleLayout {

    /// Height of a single lip (one comfortable line of text + padding).
    var lipHeight: CGFloat = 54
    /// Leading indent contributed by each visible ancestor.
    var indentWidth: CGFloat = 14
    /// Max visible ancestors (the spec's "N-1 and N-2").
    var maxVisibleAncestors: CGFloat = 2
    /// Card corner radius.
    var cornerRadius: CGFloat = 24

    /// What a layer is doing right now, for the host to apply chrome/lifecycle.
    enum Role { case focused, ancestor, tucked, emerging }

    /// Everything the host needs to place one layer for a given `focus`.
    struct Placement {
        /// Card frame in container coordinates.
        var cardFrame: CGRect
        /// Z-position: higher = closer to the user (focused is frontmost).
        var z: CGFloat
        /// Colour depth for `ReaderDepth.backgroundColor(for:)`.
        var depth: Int
        var role: Role
        /// 0 (focused, no lips) → 1 (full ancestor lips). Drives lip opacity and the
        /// focused header's inverse opacity.
        var chromeAlpha: CGFloat
        /// Whole card opacity (fades the card out only once fully tucked offscreen).
        var cardAlpha: CGFloat
        /// True while the layer should accept touches (focused content + visible
        /// ancestor lips). Tucked / fully-emerging layers are inert.
        var interactive: Bool
    }

    /// `visibleAncestors` for a (possibly fractional) focus.
    func visibleAncestors(focus: CGFloat) -> CGFloat { min(maxVisibleAncestors, max(0, focus)) }

    /// The card frame for an integer-ish inset-step count `s` (0 = backmost/full,
    /// growing inward by one lip/indent step each).
    func cardFrame(steps s: CGFloat, bounds: CGRect, safeArea: UIEdgeInsets) -> CGRect {
        let minX = s * indentWidth
        let minY = safeArea.top + s * lipHeight
        let maxY = bounds.height - safeArea.bottom - s * lipHeight
        return CGRect(x: minX, y: minY,
                      width: max(bounds.width - minX, 0),
                      height: max(maxY - minY, 0))
    }

    /// The split-line sliver a layer is born from / dies into. `splitY` is the cut in
    /// container coordinates (top of the tapped link's line); the sliver is a
    /// zero-ish-height slice of the focused frame parked at `splitY`.
    func sliverFrame(focusedSteps: CGFloat, splitY: CGFloat,
                     bounds: CGRect, safeArea: UIEdgeInsets) -> CGRect {
        let focused = cardFrame(steps: focusedSteps, bounds: bounds, safeArea: safeArea)
        return CGRect(x: focused.minX, y: splitY, width: focused.width, height: 0)
    }

    /// The full placement for one layer at a given `focus`.
    /// - Parameters:
    ///   - layerIndex: this layer's index in the stack (0 = root).
    ///   - focus: the focused layer's fractional index.
    ///   - splitY: cut line for the emerging/dying layer (nil → use focused frame).
    func placement(layerIndex i: Int, focus: CGFloat,
                   bounds: CGRect, safeArea: UIEdgeInsets,
                   splitY: CGFloat? = nil) -> Placement {
        let v = visibleAncestors(focus: focus)
        let delta = focus - CGFloat(i)
        // Inset steps: focused (δ=0) is most inset (= v); each step behind insets one
        // less. Clamped so a layer never insets past the focused frame.
        let rawSteps = v - delta
        let steps = min(max(rawSteps, 0), v)

        // z so the focused layer is frontmost and ancestors recede behind it.
        let z = -delta

        // Tuck: the 3rd+ ancestor slides off the leading edge as δ passes 2 → 3.
        let tuck = min(max(delta - maxVisibleAncestors, 0), 1)
        let translateX = -tuck * bounds.width

        var role: Role
        if delta < 0 { role = .emerging }
        else if delta < 0.001 { role = .focused }
        else if tuck >= 1 { role = .tucked }
        else { role = .ancestor }

        // Card frame: emerging layers interpolate from the sliver to the focused frame.
        var frame: CGRect
        if delta < 0, let splitY {
            let focused = cardFrame(steps: v, bounds: bounds, safeArea: safeArea)
            let sliver = sliverFrame(focusedSteps: v, splitY: splitY,
                                     bounds: bounds, safeArea: safeArea)
            let t = min(max(delta + 1, 0), 1)   // δ: -1 → 0  maps to  0 → 1
            frame = interpolate(sliver, focused, t)
        } else {
            frame = cardFrame(steps: steps, bounds: bounds, safeArea: safeArea)
        }
        frame.origin.x += translateX

        let chromeAlpha = min(max(delta, 0), 1)         // lips fade in over δ 0→1
        let cardAlpha = 1 - min(max(delta - 2.6, 0), 1) // fully gone shortly after tuck

        return Placement(
            cardFrame: frame, z: z, depth: min(max(i, 0), 4), role: role,
            chromeAlpha: chromeAlpha, cardAlpha: cardAlpha,
            interactive: role == .focused || role == .ancestor)
    }

    private func interpolate(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t,
               y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t,
               height: a.height + (b.height - a.height) * t)
    }
}

//
//  RabbitHoleLayout.swift
//  Clip
//
//  Forked, experimental "RabbitHole" reader — see RabbitHoleReaderViewController.
//

import ClipDesignSystem
import UIKit

/// Pure geometry for the RabbitHole stacked-layer reader: the static resting frame of
/// every layer for a given focused index. Transitions between two focus states are
/// rendered by the halftone wipe (`RabbitHoleTransitioning`), so this only ever needs
/// the discrete rest states — no fractional interpolation.
///
/// Model (let `δ = focusedIndex - layerIndex`, the layer's distance *behind* the focus):
/// - `δ == 0`  → the focused layer: most inset, fills the focused area, no lips.
/// - `δ == 1`  → the parent: one inset step out; a top lip, bottom lip, and leading
///               indent of its background peek around the focused layer.
/// - `δ == 2`  → the grandparent: two steps out (fills the screen behind everything),
///               its lips peek around the parent's.
/// - `δ  > 2`  → tucked fully offscreen past the leading edge (only ever the 3rd+
///               ancestor; restored as you climb back up).
///
/// At most two ancestors are ever visible at once: `visibleAncestors = min(2, focus)`.
public struct RabbitHoleLayout {

    public init() {}

    /// Height of a single lip (one comfortable line of text + padding).
    public var lipHeight: CGFloat = 54
    /// Leading indent contributed by each visible ancestor.
    public var indentWidth: CGFloat = 14
    /// Max visible ancestors (the spec's "N-1 and N-2").
    public var maxVisibleAncestors: CGFloat = 2
    /// Card corner radius.
    public var cornerRadius: CGFloat = 24

    /// What a layer is doing right now, for the host to apply chrome/lifecycle.
    public enum Role { case focused, ancestor, tucked }

    /// Everything the host needs to place one layer for a given `focus`.
    public struct Placement {
        /// Card frame in container coordinates.
        public var cardFrame: CGRect
        /// Z-position: higher = closer to the user (focused is frontmost).
        public var z: CGFloat
        /// Colour depth for `ReaderDepth.backgroundColor(for:)`.
        public var depth: Int
        public var role: Role
        /// 0 (focused, no lips) → 1 (full ancestor lips). Drives lip opacity and the
        /// focused header's inverse opacity.
        public var chromeAlpha: CGFloat
        /// Whole card opacity (fades the card out only once fully tucked offscreen).
        public var cardAlpha: CGFloat
        /// True while the layer should accept touches (focused content + visible
        /// ancestor lips). Tucked / fully-emerging layers are inert.
        public var interactive: Bool

        public init(cardFrame: CGRect, z: CGFloat, depth: Int, role: Role,
                    chromeAlpha: CGFloat, cardAlpha: CGFloat, interactive: Bool) {
            self.cardFrame = cardFrame
            self.z = z
            self.depth = depth
            self.role = role
            self.chromeAlpha = chromeAlpha
            self.cardAlpha = cardAlpha
            self.interactive = interactive
        }
    }

    /// Number of ancestors shown as lips for a focused index.
    public func visibleAncestors(focusedIndex: Int) -> Int { min(Int(maxVisibleAncestors), max(0, focusedIndex)) }

    /// The card frame for an inset-step count `s` (0 = backmost/full, growing inward by
    /// one lip/indent step each).
    public func cardFrame(steps s: Int, bounds: CGRect, safeArea: UIEdgeInsets) -> CGRect {
        let f = CGFloat(s)
        let minX = f * indentWidth
        let minY = safeArea.top + f * lipHeight
        let maxY = bounds.height - safeArea.bottom - f * lipHeight
        return CGRect(x: minX, y: minY,
                      width: max(bounds.width - minX, 0),
                      height: max(maxY - minY, 0))
    }

    /// The resting placement for one layer when `focusedIndex` is focused.
    public func placement(layerIndex i: Int, focusedIndex: Int,
                          bounds: CGRect, safeArea: UIEdgeInsets) -> Placement {
        let v = visibleAncestors(focusedIndex: focusedIndex)
        let delta = focusedIndex - i                 // 0 focused, >0 ancestor/tucked
        let steps = min(max(v - delta, 0), v)        // focused = v (most inset)

        let role: Role
        if delta <= 0 { role = .focused }
        else if delta > Int(maxVisibleAncestors) { role = .tucked }
        else { role = .ancestor }

        var frame = cardFrame(steps: steps, bounds: bounds, safeArea: safeArea)
        if role == .tucked { frame.origin.x -= bounds.width }   // off the leading edge

        return Placement(
            cardFrame: frame,
            z: CGFloat(-delta),                       // focused frontmost
            depth: min(max(i, 0), 4),
            role: role,
            chromeAlpha: delta >= 1 ? 1 : 0,          // lips on for ancestors only
            cardAlpha: role == .tucked ? 0 : 1,
            interactive: role == .focused || role == .ancestor)
    }
}

//
//  DotMatrixRegion.swift
//  ClipTransitions
//
//  UIView-level changed-region diffing for the Dot Matrix pixel-wipe.
//
//  THE RULE: a wipe should only ever cover and dissolve the screen REGIONS that
//  actually change. Genuinely-unchanged chrome (e.g. the RabbitHole reader's
//  layer-0 top/bottom "lips" during a layer-2 push/pop) must stay perfectly static
//  — it must NOT sit inside a full-screen snapshot and get pixelated mid-dissolve.
//
//  Diffing is at the UIVIEW level — region/rect based, NOT pixel-by-pixel. The
//  caller describes the before/after arrangement as a set of identified items
//  (`Item`: an id + a frame + an opaque state token). An item whose frame OR state
//  token changed (or that appears/disappears) is "changed"; its before+after frames
//  both contribute to the changed region. Items present and identical on both sides
//  are unchanged and excluded. The result is the union (bounding rect) of all
//  changed sub-rects, which the region-confined transition path then confines the
//  overlay + snapshot to.
//
//  This is the shared mechanism the RabbitHole reader, the filter animation, and the
//  mode-switch animation all reuse to confine their wipes.
//

import CoreGraphics

public enum DotMatrixRegion {

    /// One identified UIView-level participant in a before/after arrangement.
    ///
    /// `id` ties the same logical view across the before/after states. `frame` is in
    /// the host/container coordinate space. `state` is an opaque equality token for
    /// any non-geometric change that should still trigger a wipe (e.g. a layer's
    /// role, or a content-revision counter) — two items with the same `id` are
    /// "unchanged" only when BOTH their `frame` and `state` match.
    public struct Item: Equatable {
        public let id: AnyHashable
        public let frame: CGRect
        public let state: AnyHashable

        public init(id: AnyHashable, frame: CGRect, state: AnyHashable = 0) {
            self.id = id
            self.frame = frame
            self.state = state
        }
    }

    /// The union (bounding rect) of every changed sub-rect between two arrangements,
    /// or `nil` when nothing changed.
    ///
    /// An item is **changed** when, keyed by `id`: it appears in only one side, or its
    /// `frame` or `state` differs between sides. Both its before and after frames join
    /// the union (a moved/resized view must wipe the area it left and the area it
    /// entered). Items identical on both sides (same `frame` AND `state`) are excluded.
    ///
    /// Frames are intersected with `bounds` when given, so off-screen tucked cards
    /// don't inflate the region beyond the visible host.
    public static func changedRegion(before: [Item], after: [Item],
                                     in bounds: CGRect? = nil) -> CGRect? {
        var beforeByID: [AnyHashable: Item] = [:]
        for item in before { beforeByID[item.id] = item }
        var afterByID: [AnyHashable: Item] = [:]
        for item in after { afterByID[item.id] = item }

        var union: CGRect = .null

        func add(_ rect: CGRect) {
            var r = rect
            if let bounds { r = r.intersection(bounds) }
            guard !r.isNull, !r.isEmpty else { return }
            union = union.union(r)
        }

        let ids = Set(beforeByID.keys).union(afterByID.keys)
        for id in ids {
            let b = beforeByID[id]
            let a = afterByID[id]
            switch (b, a) {
            case let (b?, a?):
                // Present on both sides — changed iff frame OR state differs.
                if b.frame != a.frame || b.state != a.state {
                    add(b.frame)
                    add(a.frame)
                }
            case let (b?, nil):
                add(b.frame)        // disappeared — wipe where it was
            case let (nil, a?):
                add(a.frame)        // appeared — wipe where it now is
            case (nil, nil):
                break               // unreachable
            }
        }

        return union.isNull ? nil : union
    }

    /// Whether the changed region effectively spans the whole `bounds` (within
    /// `slack` points on every edge). When true the caller should take the plain
    /// full-screen path — confining to a region that is the whole screen buys
    /// nothing and only risks coordinate-rounding seams.
    public static func isFullScreen(_ region: CGRect, bounds: CGRect,
                                    slack: CGFloat = 1) -> Bool {
        region.minX <= bounds.minX + slack &&
        region.minY <= bounds.minY + slack &&
        region.maxX >= bounds.maxX - slack &&
        region.maxY >= bounds.maxY - slack
    }
}

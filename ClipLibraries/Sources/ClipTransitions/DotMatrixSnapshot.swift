//
//  DotMatrixSnapshot.swift
//  ClipTransitions
//
//  Rasterises a view into a UIImage for the GPU transition. Opaque and capped at 2×
//  to match the engine's drawable scale (never @3×), keeping the CPU snapshot cost
//  off the critical path as small as possible.
//

import UIKit

enum DotMatrixSnapshot {
    /// Snapshot `view`'s own hierarchy at its current bounds. `afterScreenUpdates`
    /// true flushes pending layout first (use for the post-change "after" image);
    /// false captures the already-committed state (use for the "before" image, with
    /// no forced commit). Returns nil for degenerate sizes / failed renders.
    static func image(of view: UIView, afterScreenUpdates: Bool) -> UIImage? {
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = min(view.window?.screen.scale ?? UIScreen.main.scale, 2)
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        var rendered = false
        let image = renderer.image { ctx in
            rendered = view.drawHierarchy(in: bounds, afterScreenUpdates: afterScreenUpdates)
            if !rendered { view.layer.render(in: ctx.cgContext) }
        }
        return image
    }
}

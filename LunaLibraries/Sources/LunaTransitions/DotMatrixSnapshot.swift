//
//  DotMatrixSnapshot.swift
//  LunaTransitions
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
        image(of: view, region: view.bounds, afterScreenUpdates: afterScreenUpdates)
    }

    /// Cut the sub-rect `region` (in the same point space the image was captured in,
    /// with matching origin) out of an existing snapshot. Exact for pixel-aligned
    /// regions: the crop happens on the backing CGImage at the image's own scale, so
    /// the result lines up 1:1 with a region-confined overlay at the same rect —
    /// cheaper than re-rendering the hierarchy when a full snapshot already exists.
    static func crop(_ image: UIImage, to region: CGRect) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let scale = image.scale
        let pixelRect = CGRect(x: region.origin.x * scale,
                               y: region.origin.y * scale,
                               width: region.width * scale,
                               height: region.height * scale)
        guard let cropped = cg.cropping(to: pixelRect) else { return nil }
        return UIImage(cgImage: cropped, scale: scale, orientation: image.imageOrientation)
    }

    /// Snapshot only the sub-rect `region` of `view`'s hierarchy (in `view`'s own
    /// coordinate space). The returned image is `region`-sized: the hierarchy is drawn
    /// through a translated context so the captured pixels line up exactly with that
    /// sub-rect — pass the same `region` to a region-confined overlay and the before/
    /// after textures align. Used for region-confined wipes so unchanged areas outside
    /// `region` are never captured. Returns nil for degenerate sizes / failed renders.
    static func image(of view: UIView, region: CGRect, afterScreenUpdates: Bool) -> UIImage? {
        let clamped = region.intersection(view.bounds)
        guard clamped.width > 1, clamped.height > 1 else { return nil }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = min(view.window?.screen.scale ?? UIScreen.main.scale, 2)
        format.opaque = true
        // Renderer bounds are the region's SIZE (origin .zero); translate the context so
        // the slice of the hierarchy at `clamped.origin` lands at the image origin.
        let renderer = UIGraphicsImageRenderer(
            bounds: CGRect(origin: .zero, size: clamped.size), format: format)
        var rendered = false
        let image = renderer.image { ctx in
            ctx.cgContext.translateBy(x: -clamped.origin.x, y: -clamped.origin.y)
            rendered = view.drawHierarchy(in: view.bounds, afterScreenUpdates: afterScreenUpdates)
            if !rendered { view.layer.render(in: ctx.cgContext) }
        }
        return image
    }
}

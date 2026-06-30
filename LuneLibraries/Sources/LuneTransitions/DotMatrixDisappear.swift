//
//  DotMatrixDisappear.swift
//  LuneTransitions
//
//  Dot Matrix "pixelate-out" for a view that is DISAPPEARING (going from present to
//  absent) in place — the exact mirror of `DotMatrixAppear.pixelateIn`. The view's
//  pixels dissolve dot-by-dot back into the empty background it sat on, then the view
//  is removed. When the pixel-wipe is disabled (or Metal is unavailable / the view is
//  too small to snapshot) it falls straight through to a plain fade-out so callers keep
//  a sensible default.
//
//  Scope: this animates ONLY `view` (a toast pill, a small banner) — never the chrome
//  around it. Use for discrete, self-contained disappearances; keep micro-interactions
//  that belong to other surfaces on their own animations.
//

import LuneContentRendering
import LuneDesignSystem
import UIKit

public enum DotMatrixDisappear {
    /// Pixelate `view` out of existence in place, then remove it from its superview.
    /// `view` must be in a window and laid out at its final frame (so its snapshot is
    /// correct). The live view is hidden under the wipe immediately and removed when the
    /// wipe lands. Falls back to a plain fade-out + removal when the pixel-wipe is
    /// disabled / unavailable.
    public static func pixelateOut(_ view: UIView,
                                   direction: DotMatrixWavefrontDirection = .random,
                                   duration: TimeInterval? = nil,
                                   completion: (() -> Void)? = nil) {
        view.layoutIfNeeded()

        // Mirror of `pixelateIn`: the overlay is parented in the view's SUPERVIEW (not the
        // view itself), because the disappearing view may be a `UIVisualEffectView` and
        // adding subviews directly to such a view traps on modern iOS. Hosting the overlay
        // as a sibling, framed in the superview's coordinate space, sidesteps that. No
        // superview ⇒ fall back.
        guard DotMatrixTransitionCenter.shared.isEnabled,
              let host = view.superview,
              let before = DotMatrixSnapshot.image(of: view, afterScreenUpdates: false),
              let overlay = DotMatrixTransitionCenter.shared.borrowOverlay(for: view.window) else {
            fadeOut(view, duration: duration, completion: completion)
            return
        }

        // The "after" is the empty background the pill dissolves back into: a transparent
        // image the engine fills with the gap colour, so cells melt away into blank space.
        let after = transparentImage(size: before.size)

        // Hide the real pill under the overlay; the overlay carries the dissolving pixels.
        view.alpha = 0

        overlay.style = DotMatrixTransitionStyleProvider.style(for: view.traitCollection)
        overlay.direction = direction
        overlay.frame = view.frame
        overlay.autoresizingMask = []
        overlay.configure(before: before, after: after)
        overlay.setProgress(0)
        overlay.isHidden = false
        host.insertSubview(overlay, aboveSubview: view)

        let window = view.window
        overlay.animateProgress(to: 1, duration: duration ?? DotMatrixTransitionSettings.totalDuration) {
            view.removeFromSuperview()
            DotMatrixTransitionCenter.shared.returnOverlay(overlay, for: window)
            completion?()
        }
    }

    private static func fadeOut(_ view: UIView, duration: TimeInterval?, completion: (() -> Void)?) {
        UIView.animate(withDuration: duration ?? 0.25, animations: { view.alpha = 0 }) { _ in
            view.removeFromSuperview()
            completion?()
        }
    }

    /// A fully transparent image of `size` — the empty "after" the disappearing view
    /// dissolves into. Non-opaque so the engine reads it as bare background.
    private static func transparentImage(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        format.scale = min(UIScreen.main.scale, 2)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in }
    }
}

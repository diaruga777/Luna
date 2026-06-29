//
//  DotMatrixAppear.swift
//  ClipTransitions
//
//  Dot Matrix "pixelate-in" for a view that is APPEARING (going from absent to present)
//  rather than swapping between two states of an existing view (that's DotMatrixCrossfade).
//  The before-image is the empty background the view materialises over, so the view's
//  pixels assemble dot-by-dot out of the gap colour. When the pixel-wipe is disabled (or
//  Metal is unavailable / the view is too small to snapshot) it falls straight through to
//  a plain fade so callers keep a sensible default.
//
//  Scope: this animates ONLY `view` (a toast pill, a small banner) — never the chrome
//  around it. Use for discrete, self-contained appearances; keep micro-interactions that
//  belong to other surfaces on their own animations.
//

import ClipContentRendering
import ClipDesignSystem
import UIKit

public enum DotMatrixAppear {
    /// Pixelate `view` into existence on top of its current parent. `view` must already
    /// be in a window and laid out at its final frame (so its snapshot is correct). The
    /// pill is hidden under the wipe and revealed when the wipe lands, so there's no flash.
    /// Falls back to a plain fade-in when the pixel-wipe is disabled / unavailable.
    public static func pixelateIn(_ view: UIView,
                                  direction: DotMatrixWavefrontDirection = .random,
                                  duration: TimeInterval? = nil,
                                  completion: (() -> Void)? = nil) {
        view.layoutIfNeeded()

        guard DotMatrixTransitionCenter.shared.isEnabled,
              let after = DotMatrixSnapshot.image(of: view, afterScreenUpdates: true),
              let overlay = DotMatrixTransitionCenter.shared.borrowOverlay(for: view.window) else {
            fadeIn(view, duration: duration, completion: completion)
            return
        }

        // The "before" is the empty background the pill assembles out of: a transparent
        // image the engine fills with the gap colour, so cells emerge from blank space.
        let before = transparentImage(size: after.size)

        // Hide the real pill under the overlay; reveal it the instant the wipe lands so
        // the live (interactive, tappable) view is what remains.
        view.alpha = 0

        overlay.style = DotMatrixTransitionStyleProvider.style(for: view.traitCollection)
        overlay.direction = direction
        overlay.frame = view.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.configure(before: before, after: after)
        overlay.setProgress(0)
        overlay.isHidden = false
        view.addSubview(overlay)

        let window = view.window
        overlay.animateProgress(to: 1, duration: duration ?? DotMatrixTransitionSettings.totalDuration) {
            view.alpha = 1
            DotMatrixTransitionCenter.shared.returnOverlay(overlay, for: window)
            completion?()
        }
    }

    private static func fadeIn(_ view: UIView, duration: TimeInterval?, completion: (() -> Void)?) {
        view.alpha = 0
        UIView.animate(withDuration: duration ?? 0.3, animations: { view.alpha = 1 }) { _ in
            completion?()
        }
    }

    /// A fully transparent image of `size` — the empty "before" the appearing view
    /// dissolves out of. Non-opaque so the engine reads it as bare background.
    private static func transparentImage(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        format.scale = min(UIScreen.main.scale, 2)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in }
    }
}

//
//  DotMatrixCrossfade.swift
//  LunaTransitions
//
//  Plays the Dot Matrix pixel-wipe for an in-place change to a single view (e.g. a large
//  content area swapping state) without a view-controller transition. Snapshots the
//  view, applies the change, snapshots again, and dissolves between them on a borrowed
//  overlay. When the pixel-wipe is disabled, it reproduces the change inside a plain
//  `UIView.animate` so callers get their original feel for free.
//
//  Use only for large-area, discrete changes; small/frequent micro-interactions (toasts,
//  buttons) should keep their bespoke animations — pixelating them is disproportionate.
//

import LunaContentRendering
import LunaDesignSystem
import UIKit

public enum DotMatrixCrossfade {
    /// Apply `changes` to `view` behind a Dot Matrix wipe. `direction` defaults to a
    /// random (fade-order) reveal. `duration` nil ⇒ the configured total duration.
    ///
    /// `region` (in `view`'s own coordinate space) confines the wipe to just that
    /// sub-rect: the overlay is framed and the before/after snapshots captured only
    /// there, so everything outside keeps its live views and never pixelates. Pass nil
    /// (default) to wipe the whole `view.bounds` — behaviour identical to before. Use a
    /// `DotMatrixRegion.changedRegion(...)` result here to animate only changed areas.
    ///
    /// `chromeFade` (with a `region`) is for changes where the AREA OUTSIDE the region
    /// also changes but must not pixelate — headers, footers, dimming. The pre-change
    /// screen is held on a full-`view` snapshot that CROSSFADES to the live after state
    /// over `DotMatrixModal.chromeFadeDuration` while the region wipes: chrome fades,
    /// content dissolves. Without it, everything outside the region snaps instantly.
    public static func run(in view: UIView,
                           direction: DotMatrixWavefrontDirection = .random,
                           duration: TimeInterval? = nil,
                           region: CGRect? = nil,
                           chromeFade: Bool = false,
                           changes: @escaping () -> Void,
                           completion: (() -> Void)? = nil) {
        // The sub-rect to wipe (and snapshot), clamped to the view. A region collapsing
        // to nothing means there's nothing to animate — apply the change and bail.
        let rect = (region ?? view.bounds).intersection(view.bounds)

        // Disabled / no usable before-snapshot ⇒ stock animation around the change.
        guard DotMatrixTransitionCenter.shared.isEnabled,
              rect.width > 1, rect.height > 1,
              let before = DotMatrixSnapshot.image(of: view, region: rect, afterScreenUpdates: false) else {
            UIView.animate(withDuration: duration ?? 0.3, animations: changes) { _ in completion?() }
            return
        }

        // For the chrome fade, capture the whole pre-change screen while it's still on
        // screen. Failure just means the chrome snaps instead of fading — not fatal.
        let beforeFull = chromeFade
            ? DotMatrixSnapshot.image(of: view, afterScreenUpdates: false) : nil

        changes()
        view.layoutIfNeeded()

        guard let after = DotMatrixSnapshot.image(of: view, region: rect, afterScreenUpdates: true),
              let overlay = DotMatrixTransitionCenter.shared.borrowOverlay(for: view.window) else {
            // Change is already applied; just finish.
            completion?(); return
        }

        // The held pre-change screen, fading out to reveal the live after-state chrome.
        // Sits below the overlay, so inside the region only the wipe is visible.
        if let beforeFull {
            let chrome = UIImageView(image: beforeFull)
            chrome.frame = view.bounds
            chrome.autoresizingMask = []
            chrome.contentMode = .scaleToFill
            view.addSubview(chrome)
            UIView.animate(withDuration: DotMatrixModal.chromeFadeDuration, animations: {
                chrome.alpha = 0
            }, completion: { _ in
                chrome.removeFromSuperview()
            })
        }

        overlay.style = DotMatrixTransitionStyleProvider.style(for: view.traitCollection)
        overlay.direction = direction
        overlay.frame = rect
        overlay.autoresizingMask = []
        overlay.configure(before: before, after: after)
        overlay.setProgress(0)
        overlay.isHidden = false
        view.addSubview(overlay)

        let window = view.window
        overlay.animateProgress(to: 1, duration: duration ?? DotMatrixTransitionStyle.totalDuration) {
            DotMatrixTransitionCenter.shared.returnOverlay(overlay, for: window)
            completion?()
        }
    }
}

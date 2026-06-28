//
//  HalftoneCrossfade.swift
//  ClipTransitions
//
//  Plays the halftone pixel-wipe for an in-place change to a single view (e.g. a large
//  content area swapping state) without a view-controller transition. Snapshots the
//  view, applies the change, snapshots again, and dissolves between them on a borrowed
//  overlay. When the pixel-wipe is disabled, it reproduces the change inside a plain
//  `UIView.animate` so callers get their original feel for free.
//
//  Use only for large-area, discrete changes; small/frequent micro-interactions (toasts,
//  buttons) should keep their bespoke animations — pixelating them is disproportionate.
//

import ClipContentRendering
import ClipDesignSystem
import UIKit

@MainActor
public enum HalftoneCrossfade {
    /// Apply `changes` to `view` behind a halftone wipe. `direction` defaults to a
    /// random (fade-order) reveal. `duration` nil ⇒ the configured total duration.
    public static func run(in view: UIView,
                           direction: HalftoneWavefrontDirection = .random,
                           duration: TimeInterval? = nil,
                           changes: @escaping () -> Void,
                           completion: (() -> Void)? = nil) {
        // Disabled / no usable before-snapshot ⇒ stock animation around the change.
        guard HalftoneTransitionCenter.shared.isEnabled,
              let before = HalftoneSnapshot.image(of: view, afterScreenUpdates: false) else {
            UIView.animate(withDuration: duration ?? 0.3, animations: changes) { _ in completion?() }
            return
        }

        changes()
        view.layoutIfNeeded()

        guard let after = HalftoneSnapshot.image(of: view, afterScreenUpdates: true),
              let overlay = HalftoneTransitionCenter.shared.borrowOverlay(for: view.window) else {
            // Change is already applied; just finish.
            completion?(); return
        }

        overlay.style = HalftoneTransitionStyleProvider.style(for: view.traitCollection)
        overlay.direction = direction
        overlay.frame = view.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.configure(before: before, after: after)
        overlay.setProgress(0)
        overlay.isHidden = false
        view.addSubview(overlay)

        let window = view.window
        overlay.animateProgress(to: 1, duration: duration ?? HalftoneTransitionSettings.totalDuration) {
            HalftoneTransitionCenter.shared.returnOverlay(overlay, for: window)
            completion?()
        }
    }
}

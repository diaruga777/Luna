//
//  DotMatrixTransitionSession.swift
//  ClipTransitions
//
//  The shared setup + teardown for a single GPU Dot Matrix "pixel wipe" driven by a
//  UIViewControllerContextTransitioning. Both the non-interactive `DotMatrixAnimator`
//  and the interactive `DotMatrixInteractivePopController` use this so the
//  snapshot/overlay-borrow/commit dance lives in exactly one place.
//
//  `begin(context:direction:)` synchronously parents the incoming view, snapshots
//  before/after, borrows the window's prewarmed overlay, and parks it on top at
//  progress 0 — all in one runloop so the incoming view is never seen uncovered.
//  The caller then either runs it to completion (`DotMatrixAnimator`) or drives
//  `setProgress` from a gesture and ends with `settle(committed:)` (interactive).
//

import ClipContentRendering
import UIKit

/// A live, set-up Dot Matrix wipe bound to one transition context. Holds the overlay
/// and the bookkeeping needed to finish the transition cleanly (return the overlay,
/// remove the incoming view on cancel, call `completeTransition`).
final class DotMatrixTransitionSession {

    private let ctx: UIViewControllerContextTransitioning
    private let overlay: RabbitHoleTransitionView
    private let window: UIWindow?
    private let toView: UIView
    private let isIncomingNew: Bool

    private init(ctx: UIViewControllerContextTransitioning,
                 overlay: RabbitHoleTransitionView,
                 window: UIWindow?,
                 toView: UIView,
                 isIncomingNew: Bool) {
        self.ctx = ctx
        self.overlay = overlay
        self.window = window
        self.toView = toView
        self.isIncomingNew = isIncomingNew
    }

    /// Set up the overlay + snapshots synchronously and park it on top at progress 0
    /// (the before frame). Returns nil — and the caller must complete the context as an
    /// instant cut — when the engine is unavailable or a snapshot fails. Mirrors what the
    /// old `DotMatrixAnimator.animateTransition` did up to the point it kicked off the run.
    static func begin(context ctx: UIViewControllerContextTransitioning,
                      direction: DotMatrixWavefrontDirection) -> DotMatrixTransitionSession? {
        let container = ctx.containerView
        guard let toVC = ctx.viewController(forKey: .to),
              let toView = ctx.view(forKey: .to) else { return nil }
        let fromView = ctx.view(forKey: .from)

        // Present/push add the incoming view; dismiss/pop already have it behind.
        let isIncomingNew = (toView.superview == nil)
        if isIncomingNew {
            let finalFrame = ctx.finalFrame(for: toVC)
            if !finalFrame.isEmpty { toView.frame = finalFrame }
            container.addSubview(toView)
        }
        container.layoutIfNeeded()

        let window = container.window
        let beforeView = fromView ?? toView

        guard DotMatrixTransitionCenter.shared.isEnabled,
              let beforeImg = DotMatrixSnapshot.image(of: beforeView, afterScreenUpdates: false),
              let afterImg = DotMatrixSnapshot.image(of: toView, afterScreenUpdates: true),
              let overlay = DotMatrixTransitionCenter.shared.borrowOverlay(for: window) else {
            return nil
        }

        overlay.style = DotMatrixTransitionStyleProvider.style(for: container.traitCollection)
        overlay.direction = direction
        overlay.frame = container.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.configure(before: beforeImg, after: afterImg)
        overlay.setProgress(0)
        overlay.isHidden = false
        container.addSubview(overlay)

        return DotMatrixTransitionSession(ctx: ctx, overlay: overlay, window: window,
                                         toView: toView, isIncomingNew: isIncomingNew)
    }

    /// Drive the wipe directly (0 = before, 1 = after) — interactive use.
    func setProgress(_ p: CGFloat) { overlay.setProgress(p) }

    /// Animate to the after state over `duration`, then finish the transition committed.
    /// Used by the non-interactive animator (start at 0) and by a committed interactive end.
    func runToCompletion(duration: TimeInterval) {
        overlay.animateProgress(to: 1, duration: duration) { [self] in
            finish(committed: true)
        }
    }

    /// Settle to the after state (`committed`) or back to the before state, then complete
    /// the transition. The settle is GPU-animated from the overlay's current progress.
    func settle(committed: Bool, duration: TimeInterval) {
        overlay.animateProgress(to: committed ? 1 : 0, duration: duration) { [self] in
            finish(committed: committed)
        }
    }

    /// Return the overlay, undo the incoming view on cancel, and complete the context.
    private func finish(committed: Bool) {
        if !committed && isIncomingNew { toView.removeFromSuperview() }
        DotMatrixTransitionCenter.shared.returnOverlay(overlay, for: window)
        ctx.completeTransition(committed)
    }
}

//
//  HalftoneAnimator.swift
//  ClipTransitions
//
//  The GPU halftone "pixel wipe" expressed as a UIViewControllerAnimatedTransitioning,
//  used for nav push/pop and modal present/dismiss. Snapshots the outgoing screen
//  (before) and the incoming screen (after), then plays the two-wavefront dissolve on a
//  borrowed Metal overlay — all set up synchronously in one runloop so nothing flashes.
//  If the engine is unavailable or a snapshot fails, it completes as an instant cut
//  (callers only install this animator when `HalftoneTransitionCenter.isEnabled`).
//

import ClipContentRendering
import ClipDesignSystem
import UIKit

public final class HalftoneAnimator: NSObject, UIViewControllerAnimatedTransitioning {

    private let direction: HalftoneWavefrontDirection

    public init(direction: HalftoneWavefrontDirection) {
        self.direction = direction
        super.init()
    }

    public func transitionDuration(using _: UIViewControllerContextTransitioning?) -> TimeInterval {
        HalftoneTransitionSettings.totalDuration
    }

    public func animateTransition(using ctx: UIViewControllerContextTransitioning) {
        let container = ctx.containerView
        guard let toVC = ctx.viewController(forKey: .to),
              let toView = ctx.view(forKey: .to) else {
            ctx.completeTransition(!ctx.transitionWasCancelled); return
        }
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

        // Set up the overlay + snapshots synchronously; UIKit commits once at the end of
        // this runloop, so the incoming view is never seen uncovered.
        guard HalftoneTransitionCenter.shared.isEnabled,
              let beforeImg = HalftoneSnapshot.image(of: beforeView, afterScreenUpdates: false),
              let afterImg = HalftoneSnapshot.image(of: toView, afterScreenUpdates: true),
              let overlay = HalftoneTransitionCenter.shared.borrowOverlay(for: window) else {
            ctx.completeTransition(!ctx.transitionWasCancelled); return
        }

        overlay.style = HalftoneTransitionStyleProvider.style(for: container.traitCollection)
        overlay.direction = direction
        overlay.frame = container.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.configure(before: beforeImg, after: afterImg)
        overlay.setProgress(0)
        overlay.isHidden = false
        container.addSubview(overlay)

        overlay.animateProgress(to: 1, duration: transitionDuration(using: ctx)) {
            let cancelled = ctx.transitionWasCancelled
            if cancelled && isIncomingNew { toView.removeFromSuperview() }
            HalftoneTransitionCenter.shared.returnOverlay(overlay, for: window)
            ctx.completeTransition(!cancelled)
        }
    }
}

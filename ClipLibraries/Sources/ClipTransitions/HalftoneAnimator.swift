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
        // Shared setup (snapshot + borrow overlay + park on top at progress 0); nil ⇒ the
        // engine is unavailable or a snapshot failed, so fall through to an instant cut.
        guard let session = HalftoneTransitionSession.begin(context: ctx, direction: direction) else {
            ctx.completeTransition(!ctx.transitionWasCancelled); return
        }
        session.runToCompletion(duration: transitionDuration(using: ctx))
    }
}

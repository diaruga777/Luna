//
//  HalftoneInteractivePopController.swift
//  ClipTransitions
//
//  The interactive counterpart to `HalftoneAnimator`: a
//  `UIViewControllerInteractiveTransitioning` that drives the GPU halftone wipe
//  finger-for-finger. `UIPercentDrivenInteractiveTransition` can't be used here — it
//  scrubs a CAAnimation's `timeOffset`, but the wipe is rendered by a Metal overlay
//  via a CADisplayLink, NOT a CAAnimation. So this owns a `HalftoneTransitionSession`
//  and maps gesture fraction → `overlay.setProgress` directly.
//
//  Lifecycle: `startInteractiveTransition(_:)` does the same before/after snapshot +
//  overlay borrow as the animator but does NOT auto-run. A driver (the edge-pan
//  handler) calls `update(_:)` as the finger moves, then exactly one of `finish()` /
//  `cancel()`, which GPU-animate the overlay to 1 / 0 and complete the transition.
//

import ClipContentRendering
import UIKit

public final class HalftoneInteractivePopController: NSObject, UIViewControllerInteractiveTransitioning {

    private let direction: HalftoneWavefrontDirection
    private var session: HalftoneTransitionSession?
    /// True once the gesture interaction has actually started driving a context. A driver
    /// checks this to know whether `finish`/`cancel` will do anything.
    public private(set) var isActive = false

    public init(direction: HalftoneWavefrontDirection) {
        self.direction = direction
        super.init()
    }

    public func startInteractiveTransition(_ ctx: UIViewControllerContextTransitioning) {
        guard let session = HalftoneTransitionSession.begin(context: ctx, direction: direction) else {
            // Engine unavailable / snapshot failed: there's nothing to drive, so cancel the
            // interactive pop immediately (UIKit puts the from-VC back).
            ctx.completeTransition(false)
            return
        }
        self.session = session
        isActive = true
    }

    /// Scrub the wipe (0 = before/stay, 1 = after/popped). Clamped.
    public func update(_ fraction: CGFloat) {
        session?.setProgress(min(max(fraction, 0), 1))
    }

    /// Commit: settle the wipe to the after state, then complete the pop.
    public func finish(duration: TimeInterval) {
        guard let session else { return }
        self.session = nil
        isActive = false
        session.settle(committed: true, duration: duration)
    }

    /// Cancel: reverse the wipe back to the before state, then unwind the pop.
    public func cancel(duration: TimeInterval) {
        guard let session else { return }
        self.session = nil
        isActive = false
        session.settle(committed: false, duration: duration)
    }
}

//
//  DotMatrixTransitionSession.swift
//  LunaTransitions
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

import LunaContentRendering
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
    /// The navigation bar hidden under the wipe (so it can't snap/blink above the overlay)
    /// and its alpha to restore on completion. Nil for non-nav transitions or a hidden bar.
    private let hiddenBar: UINavigationBar?
    private let restoreBarAlpha: CGFloat

    private init(ctx: UIViewControllerContextTransitioning,
                 overlay: RabbitHoleTransitionView,
                 window: UIWindow?,
                 toView: UIView,
                 isIncomingNew: Bool,
                 hiddenBar: UINavigationBar?,
                 restoreBarAlpha: CGFloat) {
        self.ctx = ctx
        self.overlay = overlay
        self.window = window
        self.toView = toView
        self.isIncomingNew = isIncomingNew
        self.hiddenBar = hiddenBar
        self.restoreBarAlpha = restoreBarAlpha
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

        guard DotMatrixTransitionCenter.shared.isEnabled else { return nil }

        // The navigation bar is a sibling ABOVE the transition container, and UIKit swaps
        // its items to the destination's BEFORE our animator runs — so a live bar would
        // either snap (interactive pop) or blink (push/pop to a bar-hiding screen) above
        // the overlay. Fold it INTO the wipe instead: snapshot the source bar now, the
        // destination bar after the lifecycle flush, composite each into its frame, and
        // keep the live bar hidden for the whole wipe (restored on completion). The header
        // then dissolves proportionally with the content and tracks an interactive gesture.
        let fromVC = ctx.viewController(forKey: .from)
        let nav = toVC.navigationController ?? fromVC?.navigationController
        let bar = nav?.navigationBar
        // Bar frame in the snapshot (container) coordinate space. The SOURCE bar's frame is
        // captured up front (it still reflects the outgoing screen's bar); the DESTINATION
        // bar's frame is captured AFTER the lifecycle flush below, because a pop to a
        // large-title screen lays the bar out taller/differently than the compact source —
        // compositing both at one frame would clip the destination header into the short
        // source rect and it would only appear when the live bar's alpha is restored at the
        // very end of the wipe.
        func barFrameInContainer() -> CGRect? {
            bar.flatMap { $0.superview?.convert($0.frame, to: container) }
        }
        let sourceBarFrame = barFrameInContainer()
        // Snapshot the bar only while it's actually on screen (a bar-hiding destination
        // leaves it nil so we don't fold a ghost header into that side of the wipe).
        func barSnapshot() -> UIImage? {
            guard let bar, !bar.isHidden, bar.alpha > 0.01 else { return nil }
            return DotMatrixSnapshot.image(of: bar, afterScreenUpdates: false)
        }
        let sourceBarImg = barSnapshot()

        // Capture the before content (still the on-screen from-view) BEFORE the to-view is
        // added / laid out, so it's the genuine outgoing screen.
        let beforeView = fromView ?? toView
        guard let beforeContent = DotMatrixSnapshot.image(of: beforeView, afterScreenUpdates: false)
        else { return nil }

        // Present/push add the incoming view; dismiss/pop already have it behind.
        let isIncomingNew = (toView.superview == nil)
        if isIncomingNew {
            let finalFrame = ctx.finalFrame(for: toVC)
            if !finalFrame.isEmpty { toView.frame = finalFrame }
            container.addSubview(toView)
        }
        container.layoutIfNeeded()

        // The after content (afterScreenUpdates:true flushes the to-VC's viewWillAppear, so
        // any setNavigationBarHidden it does is applied and the bar now reflects the
        // destination). Capture the destination bar AFTER that flush.
        guard let afterContent = DotMatrixSnapshot.image(of: toView, afterScreenUpdates: true)
        else { return nil }
        // The flush above committed the destination bar's layout, so this snapshot + frame
        // are the FULL destination header at its final (e.g. large-title) bounds.
        let destBarImg = barSnapshot()
        let destBarFrame = barFrameInContainer()

        let window = container.window
        let beforeImg = composite(content: beforeContent, bar: sourceBarImg,
                                  at: sourceBarFrame, size: container.bounds.size)
        let afterImg = composite(content: afterContent, bar: destBarImg,
                                 at: destBarFrame, size: container.bounds.size)
        guard let overlay = DotMatrixTransitionCenter.shared.borrowOverlay(for: window) else {
            return nil
        }

        // Hide the live bar for the duration so the composited one in the snapshots is the
        // only header on screen during the wipe; restore its alpha (the destination
        // hidden-state is already correct) on completion.
        let restoreAlpha = bar?.alpha ?? 1
        let hiddenBar: UINavigationBar?
        if let bar, sourceBarImg != nil || destBarImg != nil {
            bar.alpha = 0
            hiddenBar = bar
        } else {
            hiddenBar = nil
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
                                         toView: toView, isIncomingNew: isIncomingNew,
                                         hiddenBar: hiddenBar, restoreBarAlpha: restoreAlpha)
    }

    /// Draw `content` and (if present) the navigation `bar` snapshot at `frame` into one
    /// image, so the header is part of the wipe rather than a live sibling floating above
    /// the overlay. Returns the content unchanged when there's no bar to fold in.
    static func composite(content: UIImage, bar: UIImage?,
                          at frame: CGRect?, size: CGSize) -> UIImage {
        guard let bar, let frame, size.width > 1, size.height > 1 else { return content }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = content.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            content.draw(in: CGRect(origin: .zero, size: size))
            bar.draw(in: frame)
        }
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

    /// Return the overlay, undo the incoming view on cancel, restore the live nav bar, and
    /// complete the context. The bar's hidden-state is already what the surviving screen
    /// wants (committed → destination; cancelled → UIKit re-asserts the source); we only
    /// undo the alpha we forced to 0 for the wipe.
    private func finish(committed: Bool) {
        if !committed && isIncomingNew { toView.removeFromSuperview() }
        hiddenBar?.alpha = restoreBarAlpha
        DotMatrixTransitionCenter.shared.returnOverlay(overlay, for: window)
        ctx.completeTransition(committed)
    }
}

//
//  DotMatrixModalTransitioningDelegate.swift
//  LuneTransitions
//
//  The Dot Matrix pixel-wipe for modal present/dismiss. Direction mirrors the base modal
//  style: a vertical cover sweeps up on present / down on dismiss; a cross-dissolve uses
//  the random (fade-order) wavefront. UIKit holds `transitioningDelegate` weakly, so the
//  `DotMatrixModal.present` convenience keeps the delegate alive for the presented VC's
//  lifetime via an associated object.
//

import LuneContentRendering
import LuneDesignSystem
import UIKit

public final class DotMatrixModalTransitioningDelegate: NSObject, UIViewControllerTransitioningDelegate {

    private let presentDirection: DotMatrixWavefrontDirection
    private let dismissDirection: DotMatrixWavefrontDirection

    public init(present: DotMatrixWavefrontDirection, dismiss: DotMatrixWavefrontDirection) {
        self.presentDirection = present
        self.dismissDirection = dismiss
        super.init()
    }

    /// Modal present/dismiss use the random (scattered dot-by-dot) wavefront — modals
    /// aren't a left/right navigation, so a directional sweep would read wrong. The
    /// directional wavefronts are reserved for nav push (R→L) / pop (L→R).
    public static func forStyle(_ style: UIModalTransitionStyle) -> DotMatrixModalTransitioningDelegate {
        DotMatrixModalTransitioningDelegate(present: .random, dismiss: .random)
    }

    public func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController,
        source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        guard DotMatrixTransitionCenter.shared.isEnabled else { return nil }
        return DotMatrixModalAnimator(direction: presentDirection, operation: .present)
    }

    public func animationController(
        forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        guard DotMatrixTransitionCenter.shared.isEnabled else { return nil }
        return DotMatrixModalAnimator(direction: dismissDirection, operation: .dismiss)
    }
}

private final class DotMatrixModalAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    enum Operation {
        case present
        case dismiss
    }

    private let direction: DotMatrixWavefrontDirection
    private let operation: Operation

    init(direction: DotMatrixWavefrontDirection, operation: Operation) {
        self.direction = direction
        self.operation = operation
        super.init()
    }

    func transitionDuration(using _: UIViewControllerContextTransitioning?) -> TimeInterval {
        DotMatrixTransitionSettings.totalDuration
    }

    func animateTransition(using ctx: UIViewControllerContextTransitioning) {
        switch operation {
        case .present:
            animatePresent(using: ctx)
        case .dismiss:
            animateDismiss(using: ctx)
        }
    }

    private func animatePresent(using ctx: UIViewControllerContextTransitioning) {
        let container = ctx.containerView
        guard DotMatrixTransitionCenter.shared.isEnabled,
              let toVC = ctx.viewController(forKey: .to),
              let toView = ctx.view(forKey: .to) else {
            ctx.completeTransition(!ctx.transitionWasCancelled)
            return
        }

        let finalFrame = presentedFrame(for: toVC, contextFrame: ctx.finalFrame(for: toVC), fallback: container.bounds)
        guard let before = backgroundSnapshot(in: container, frame: finalFrame, ctx: ctx) else {
            toView.frame = finalFrame
            if toView.superview == nil { container.addSubview(toView) }
            ctx.completeTransition(!ctx.transitionWasCancelled)
            return
        }

        toView.frame = finalFrame
        if toView.superview == nil {
            container.addSubview(toView)
        }
        container.layoutIfNeeded()

        guard let after = DotMatrixSnapshot.image(of: toView, afterScreenUpdates: true),
              let overlay = DotMatrixTransitionCenter.shared.borrowOverlay(for: container.window) else {
            ctx.completeTransition(!ctx.transitionWasCancelled)
            return
        }

        toView.alpha = 0
        configure(overlay, before: before, after: after, frame: finalFrame, in: container)
        overlay.animateProgress(to: 1, duration: transitionDuration(using: ctx)) {
            toView.alpha = 1
            DotMatrixTransitionCenter.shared.returnOverlay(overlay, for: container.window)
            ctx.completeTransition(!ctx.transitionWasCancelled)
        }
    }

    private func animateDismiss(using ctx: UIViewControllerContextTransitioning) {
        let container = ctx.containerView
        guard DotMatrixTransitionCenter.shared.isEnabled,
              let fromView = ctx.view(forKey: .from) else {
            ctx.completeTransition(!ctx.transitionWasCancelled)
            return
        }

        let fromVC = ctx.viewController(forKey: .from)
        let modalFrame = fromVC.map {
            presentedFrame(for: $0, contextFrame: fromView.frame, fallback: container.bounds)
        } ?? modalFrame(fromView.frame, fallback: container.bounds)
        guard let before = DotMatrixSnapshot.image(of: fromView, afterScreenUpdates: false) else {
            ctx.completeTransition(!ctx.transitionWasCancelled)
            return
        }

        if let toView = ctx.view(forKey: .to), toView.superview == nil {
            container.insertSubview(toView, belowSubview: fromView)
            let toVC = ctx.viewController(forKey: .to)
            let finalFrame = toVC.map {
                presentedFrame(for: $0, contextFrame: ctx.finalFrame(for: $0), fallback: container.bounds)
            } ?? container.bounds
            if !finalFrame.isEmpty { toView.frame = finalFrame }
            container.layoutIfNeeded()
        }

        let oldAlpha = fromView.alpha
        fromView.alpha = 0
        let after = backgroundSnapshot(in: container, frame: modalFrame, ctx: ctx)
        fromView.alpha = oldAlpha

        guard let after,
              let overlay = DotMatrixTransitionCenter.shared.borrowOverlay(for: container.window) else {
            ctx.completeTransition(!ctx.transitionWasCancelled)
            return
        }

        fromView.alpha = 0
        configure(overlay, before: before, after: after, frame: modalFrame, in: container)
        overlay.animateProgress(to: 1, duration: transitionDuration(using: ctx)) {
            fromView.alpha = oldAlpha
            DotMatrixTransitionCenter.shared.returnOverlay(overlay, for: container.window)
            ctx.completeTransition(!ctx.transitionWasCancelled)
        }
    }

    private func configure(_ overlay: RabbitHoleTransitionView,
                           before: UIImage,
                           after: UIImage,
                           frame: CGRect,
                           in container: UIView) {
        overlay.style = DotMatrixTransitionStyleProvider.style(for: container.traitCollection)
        overlay.direction = direction
        overlay.frame = frame
        overlay.autoresizingMask = []
        overlay.configure(before: before, after: after)
        overlay.setProgress(0)
        overlay.isHidden = false
        container.addSubview(overlay)
    }

    private func backgroundSnapshot(in container: UIView,
                                    frame: CGRect,
                                    ctx: UIViewControllerContextTransitioning) -> UIImage? {
        if let snapshot = DotMatrixSnapshot.image(of: container, region: frame, afterScreenUpdates: false) {
            return snapshot
        }

        guard let fromView = ctx.view(forKey: .from) else { return nil }
        let sourceFrame = container.convert(frame, to: fromView)
        return DotMatrixSnapshot.image(of: fromView, region: sourceFrame, afterScreenUpdates: false)
    }

    private func modalFrame(_ frame: CGRect, fallback: CGRect) -> CGRect {
        if frame.width > 1, frame.height > 1 { return frame }
        return fallback
    }

    private func presentedFrame(for viewController: UIViewController,
                                contextFrame: CGRect,
                                fallback: CGRect) -> CGRect {
        if let frame = viewController.presentationController?.frameOfPresentedViewInContainerView,
           frame.width > 1, frame.height > 1 {
            return frame
        }
        return modalFrame(contextFrame, fallback: fallback)
    }
}

/// Convenience for presenting with the Dot Matrix pixel-wipe. Owns the transitioning
/// delegate (UIKit only holds it weakly) by attaching it to the presented VC.
public enum DotMatrixModal {

    /// Present `vc` from `presenter`. The modal pixel-wipe is disabled for now, so this
    /// uses the stock UIKit animation. To bring the wipe back, attach
    /// `DotMatrixModalTransitioningDelegate.forStyle(vc.modalTransitionStyle)` as `vc`'s
    /// `transitioningDelegate`, keeping it alive for `vc`'s lifetime via an associated
    /// object (UIKit only holds `transitioningDelegate` weakly).
    public static func present(_ vc: UIViewController,
                               from presenter: UIViewController,
                               animated: Bool = true,
                               completion: (() -> Void)? = nil) {
        presenter.present(vc, animated: animated, completion: completion)
    }
}

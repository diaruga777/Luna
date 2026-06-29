//
//  DotMatrixModalTransitioningDelegate.swift
//  ClipTransitions
//
//  The Dot Matrix pixel-wipe for modal present/dismiss. Direction mirrors the base modal
//  style: a vertical cover sweeps up on present / down on dismiss; a cross-dissolve uses
//  the random (fade-order) wavefront. UIKit holds `transitioningDelegate` weakly, so the
//  `DotMatrixModal.present` convenience keeps the delegate alive for the presented VC's
//  lifetime via an associated object.
//

import ClipContentRendering
import ObjectiveC
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
        return DotMatrixAnimator(direction: presentDirection)
    }

    public func animationController(
        forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        guard DotMatrixTransitionCenter.shared.isEnabled else { return nil }
        return DotMatrixAnimator(direction: dismissDirection)
    }
}

/// Convenience for presenting with the Dot Matrix pixel-wipe. Owns the transitioning
/// delegate (UIKit only holds it weakly) by attaching it to the presented VC.
public enum DotMatrixModal {
    private static var delegateKey: UInt8 = 0

    /// Present `vc` from `presenter` with a Dot Matrix wipe whose direction mirrors
    /// `vc.modalTransitionStyle`. Falls through to the stock animation when the
    /// pixel-wipe is disabled (the delegate just returns nil animators).
    public static func present(_ vc: UIViewController,
                               from presenter: UIViewController,
                               animated: Bool = true,
                               completion: (() -> Void)? = nil) {
        let delegate = DotMatrixModalTransitioningDelegate.forStyle(vc.modalTransitionStyle)
        objc_setAssociatedObject(vc, &delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        vc.transitioningDelegate = delegate
        presenter.present(vc, animated: animated, completion: completion)
    }
}

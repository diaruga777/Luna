//
//  HalftoneModalTransitioningDelegate.swift
//  ClipTransitions
//
//  The halftone pixel-wipe for modal present/dismiss. Direction mirrors the base modal
//  style: a vertical cover sweeps up on present / down on dismiss; a cross-dissolve uses
//  the random (fade-order) wavefront. UIKit holds `transitioningDelegate` weakly, so the
//  `HalftoneModal.present` convenience keeps the delegate alive for the presented VC's
//  lifetime via an associated object.
//

import ClipContentRendering
import ObjectiveC
import UIKit

@MainActor
public final class HalftoneModalTransitioningDelegate: NSObject, UIViewControllerTransitioningDelegate {

    private let presentDirection: HalftoneWavefrontDirection
    private let dismissDirection: HalftoneWavefrontDirection

    public init(present: HalftoneWavefrontDirection, dismiss: HalftoneWavefrontDirection) {
        self.presentDirection = present
        self.dismissDirection = dismiss
        super.init()
    }

    /// Map a modal transition style to wavefront directions that mirror it.
    public static func forStyle(_ style: UIModalTransitionStyle) -> HalftoneModalTransitioningDelegate {
        switch style {
        case .crossDissolve:
            return HalftoneModalTransitioningDelegate(present: .random, dismiss: .random)
        case .coverVertical:
            return HalftoneModalTransitioningDelegate(present: .bottomToTop, dismiss: .topToBottom)
        default:
            // .flipHorizontal / .partialCurl and anything new — fall back to a fade.
            return HalftoneModalTransitioningDelegate(present: .random, dismiss: .random)
        }
    }

    public func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController,
        source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        guard HalftoneTransitionCenter.shared.isEnabled else { return nil }
        return HalftoneAnimator(direction: presentDirection)
    }

    public func animationController(
        forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        guard HalftoneTransitionCenter.shared.isEnabled else { return nil }
        return HalftoneAnimator(direction: dismissDirection)
    }
}

/// Convenience for presenting with the halftone pixel-wipe. Owns the transitioning
/// delegate (UIKit only holds it weakly) by attaching it to the presented VC.
public enum HalftoneModal {
    private static var delegateKey: UInt8 = 0

    /// Present `vc` from `presenter` with a halftone wipe whose direction mirrors
    /// `vc.modalTransitionStyle`. Falls through to the stock animation when the
    /// pixel-wipe is disabled (the delegate just returns nil animators).
    @MainActor
    public static func present(_ vc: UIViewController,
                               from presenter: UIViewController,
                               animated: Bool = true,
                               completion: (() -> Void)? = nil) {
        let delegate = HalftoneModalTransitioningDelegate.forStyle(vc.modalTransitionStyle)
        objc_setAssociatedObject(vc, &delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        vc.transitioningDelegate = delegate
        presenter.present(vc, animated: animated, completion: completion)
    }
}

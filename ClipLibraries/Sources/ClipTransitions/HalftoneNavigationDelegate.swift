//
//  HalftoneNavigationDelegate.swift
//  ClipTransitions
//
//  Installs the halftone pixel-wipe on a navigation controller's push/pop. Push sweeps
//  right-to-left and pop left-to-right, mirroring the stock slide. Returns nil (⇒ the
//  stock animation) whenever the pixel-wipe is disabled or Metal is unavailable, so the
//  fallback is free. A single shared, stateless delegate covers every nav controller.
//

import ClipContentRendering
import UIKit

public final class HalftoneNavigationDelegate: NSObject, UINavigationControllerDelegate {
    public static let shared = HalftoneNavigationDelegate()

    public func navigationController(
        _ navigationController: UINavigationController,
        animationControllerFor operation: UINavigationController.Operation,
        from fromVC: UIViewController,
        to toVC: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        guard HalftoneTransitionCenter.shared.isEnabled else { return nil }
        switch operation {
        case .push: return HalftoneAnimator(direction: .rightToLeft)
        case .pop:  return HalftoneAnimator(direction: .leftToRight)
        default:    return nil
        }
    }
}

public extension UINavigationController {
    /// Route this nav controller's push/pop through the halftone pixel-wipe. Only takes
    /// effect when the toggle is on; no-op if the controller already has its own
    /// delegate (so bespoke nav delegates aren't clobbered).
    func installHalftoneTransitions() {
        if delegate == nil { delegate = HalftoneNavigationDelegate.shared }
    }
}

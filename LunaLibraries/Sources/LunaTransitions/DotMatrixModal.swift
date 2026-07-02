//
//  DotMatrixModal.swift
//  LunaTransitions
//
//  The modal-present convenience. The former pixel-wipe delegate/animator that
//  lived here was disabled and then removed — see `DotMatrixModal.present`'s doc
//  for how to bring the wipe back (the nav push/pop wipe lives in DotMatrixAnimator).
//

import UIKit

/// The app-wide modal-present convenience.
public enum DotMatrixModal {

    /// Present `vc` from `presenter`. The modal pixel-wipe is disabled, so this
    /// uses the stock UIKit animation. To bring the wipe back, reintroduce a
    /// `UIViewControllerTransitioningDelegate` over `DotMatrixTransitionSession`
    /// and attach it here, kept alive via an associated object (UIKit only holds
    /// `transitioningDelegate` weakly) — see git history for the removed one.
    public static func present(_ vc: UIViewController,
                               from presenter: UIViewController,
                               animated: Bool = true,
                               completion: (() -> Void)? = nil) {
        presenter.present(vc, animated: animated, completion: completion)
    }
}

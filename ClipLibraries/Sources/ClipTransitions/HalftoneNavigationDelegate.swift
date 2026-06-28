//
//  HalftoneNavigationDelegate.swift
//  ClipTransitions
//
//  Installs the halftone pixel-wipe on a navigation controller's push/pop, AND a custom
//  left-edge-swipe back that drives the pop's wipe interactively (finger-for-finger).
//
//  Push sweeps right-to-left and pop left-to-right, mirroring the stock slide. A button
//  pop uses the NON-interactive `HalftoneAnimator`; an edge-swipe pop is driven by
//  `HalftoneInteractivePopController` via this delegate's `interactionControllerFor`.
//
//  Returns nil (⇒ the stock animation) whenever the pixel-wipe is disabled or Metal is
//  unavailable, so the fallback is free. When disabled we also leave the system's
//  `interactivePopGestureRecognizer` enabled (our edge pan refuses to begin), so the
//  standard interactive back-swipe keeps working untouched.
//
//  Unlike the old stateless shared delegate, this is ONE INSTANCE PER nav controller
//  (it owns that nav's edge gesture + the in-flight interaction controller). The
//  instance is retained by the nav controller via `installHalftoneTransitions()`.
//

import ClipContentRendering
import ClipDesignSystem
import UIKit

public final class HalftoneNavigationDelegate: NSObject, UINavigationControllerDelegate,
                                               UIGestureRecognizerDelegate {

    private weak var navigationController: UINavigationController?
    private var edgePan: UIScreenEdgePanGestureRecognizer?

    /// The interaction controller for the pop currently being driven by an edge swipe,
    /// or nil for a non-interactive (button) pop. Set just before we call
    /// `popViewController` so `interactionControllerFor` can hand it back to UIKit.
    private var interactivePop: HalftoneInteractivePopController?

    /// Width used to normalise the drag into a 0…1 fraction (set on .began).
    private var dragWidth: CGFloat = 1

    // MARK: UINavigationControllerDelegate

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

    public func navigationController(
        _ navigationController: UINavigationController,
        interactionControllerFor animationController: UIViewControllerAnimatedTransitioning)
        -> UIViewControllerInteractiveTransitioning? {
        // Only an edge-swipe-initiated pop is interactive; a button pop returns nil so the
        // non-interactive HalftoneAnimator runs as usual.
        interactivePop
    }

    // MARK: Edge-swipe install

    fileprivate func attach(to nav: UINavigationController) {
        navigationController = nav
        nav.delegate = self
        if edgePan == nil {
            let pan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
            pan.edges = .left
            pan.delegate = self
            nav.view.addGestureRecognizer(pan)
            edgePan = pan
        }
        // Setting a custom UINavigationControllerDelegate makes UIKit disable the system
        // interactive back-swipe by default. Keep it enabled so that when the wipe toggle
        // is OFF (our edge pan refuses to begin) the stock interactive pop still works.
        nav.interactivePopGestureRecognizer?.isEnabled = true
    }

    @objc private func handleEdgePan(_ pan: UIScreenEdgePanGestureRecognizer) {
        guard let nav = navigationController else { return }
        let width = max(nav.view.bounds.width, 1)

        switch pan.state {
        case .began:
            // Only start an interactive halftone pop when the wipe is enabled and there's
            // something to pop. (When disabled, our pan refuses to begin — see
            // gestureRecognizerShouldBegin — so we never reach here.)
            guard HalftoneTransitionCenter.shared.isEnabled,
                  nav.viewControllers.count > 1,
                  nav.transitionCoordinator == nil else { return }
            dragWidth = width
            let controller = HalftoneInteractivePopController(direction: .leftToRight)
            interactivePop = controller
            // Triggering the pop makes UIKit ask us for the animation + interaction
            // controllers; `interactionControllerFor` returns `controller`, whose
            // `startInteractiveTransition` sets up the overlay at progress 0.
            nav.popViewController(animated: true)
        case .changed:
            interactivePop?.update(pan.translation(in: nav.view).x / dragWidth)
        case .ended, .cancelled, .failed:
            guard let controller = interactivePop else { return }
            interactivePop = nil
            let fraction = pan.translation(in: nav.view).x / dragWidth
            let velocity = pan.velocity(in: nav.view).x
            let committed = pan.state == .ended && (fraction > 0.4 || velocity > 800)
            let duration = HalftoneTransitionSettings.totalDuration
            if committed { controller.finish(duration: duration) }
            else { controller.cancel(duration: duration) }
        default:
            break
        }
    }

    // MARK: UIGestureRecognizerDelegate

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === edgePan, let nav = navigationController else { return true }
        // Own the back-swipe only while the wipe is enabled and a pop is possible; otherwise
        // step aside so UIKit's own interactivePopGestureRecognizer runs the stock swipe.
        guard HalftoneTransitionCenter.shared.isEnabled,
              nav.viewControllers.count > 1,
              nav.transitionCoordinator == nil else { return false }
        return true
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        // Our edge pan should win over the system back-swipe so they never both fire.
        gestureRecognizer === edgePan && other === navigationController?.interactivePopGestureRecognizer
    }
}

public extension UINavigationController {
    /// Route this nav controller's push/pop through the halftone pixel-wipe and install
    /// the interactive left-edge-swipe back. Only takes visible effect when the toggle is
    /// on; no-op if the controller already has its own (non-halftone) delegate (so bespoke
    /// nav delegates aren't clobbered). Idempotent.
    func installHalftoneTransitions() {
        if delegate == nil {
            let d = HalftoneNavigationDelegate()
            d.attach(to: self)
            // Retain the per-nav delegate: UINavigationController.delegate is weak.
            objc_setAssociatedObject(self, &Self.halftoneDelegateKey, d,
                                     .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        } else if let existing = delegate as? HalftoneNavigationDelegate {
            existing.attach(to: self)   // re-attach (e.g. re-install after a scene rebuild)
        }
    }

    private static var halftoneDelegateKey: UInt8 = 0
}

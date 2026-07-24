//
//  InteractivePopGestureClaim.swift
//  LunaDesignSystem
//

import UIKit

/// Keeps UIKit's left-edge "swipe back" gesture working on a screen that hides the
/// navigation bar in favour of an in-content `NavHeaderBar` — hiding the bar (or
/// replacing the left bar-button item) is what suppresses the recognizer in the
/// first place.
///
/// Own one per screen: `claim(in:)` from `viewDidAppear`, `release()` from
/// `viewWillDisappear`, so the recognizer's original delegate is restored before
/// another screen becomes visible.
public final class InteractivePopGestureClaim: NSObject, UIGestureRecognizerDelegate {

    private weak var navigationController: UINavigationController?
    private weak var previousDelegate: UIGestureRecognizerDelegate?

    public override init() { super.init() }

    public func claim(in navigationController: UINavigationController?) {
        guard let navigationController,
              let gesture = navigationController.interactivePopGestureRecognizer else { return }
        self.navigationController = navigationController
        if gesture.delegate !== self { previousDelegate = gesture.delegate }
        gesture.delegate = self
        gesture.isEnabled = true
    }

    public func release() {
        guard let gesture = navigationController?.interactivePopGestureRecognizer,
              gesture.delegate === self else { return }
        gesture.delegate = previousDelegate
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let navigationController,
              gestureRecognizer === navigationController.interactivePopGestureRecognizer
        else { return true }
        // Nothing to pop to, and never start a second interactive transition while
        // the stack is already pushing or popping.
        guard navigationController.viewControllers.count > 1 else { return false }
        return navigationController.transitionCoordinator == nil
    }
}

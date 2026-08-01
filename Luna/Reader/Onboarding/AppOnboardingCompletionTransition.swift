//
//  AppOnboardingCompletionTransition.swift
//  Luna
//

import LunaDesignSystem
import UIKit

enum AppOnboardingCompletionTransition {
    static let handoffDuration: TimeInterval = 0.24

    static func run(in window: UIWindow, to root: UIViewController) {
        let bounds = window.bounds
        guard window.windowScene?.activationState == .foregroundActive else {
            install(root, in: window)
            root.view.frame = bounds
            root.view.layoutIfNeeded()
            root.descendantNavigationController()?.installLunarEclipseTransition()
            OnboardingAnimationClock.restoreNormalSpeed(in: window)
            return
        }
        guard let snapshot = window.snapshotView(afterScreenUpdates: true) else {
            install(root, in: window)
            OnboardingAnimationClock.restoreNormalSpeed(in: window)
            return
        }
        snapshot.frame = bounds

        install(root, in: window)
        root.view.frame = bounds
        root.view.layoutIfNeeded()
        root.view.alpha = 1
        root.descendantNavigationController()?.installLunarEclipseTransition()

        let target = root.appLaunchTransitionTarget()
        window.addSubview(snapshot)
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled
                ? 0.10
                : handoffDuration,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState]
        ) {
            snapshot.alpha = 0
        } completion: { _ in
            snapshot.removeFromSuperview()
            target?.appLaunchTransitionDidFinish()
            OnboardingAnimationClock.restoreNormalSpeed(in: window)
        }
    }

    /// Detaches the (possibly preloaded) root from onboarding and makes it the
    /// window's own root, then SETTLES its appearance state.
    ///
    /// The root is normally mounted as a hidden child long before the handoff, so
    /// UIKit has an appearance transition in flight for it — `viewWillAppear`
    /// delivered, `viewDidAppear` not yet. Reparenting mid-transition unbalances
    /// that bookkeeping: the tree ends up in the DISAPPEARED state while its views
    /// are on screen, and `viewDidAppear` is never delivered at all. Anything that
    /// keys off that one-shot then never runs — the card deck learns it is visible
    /// there, so without this every card sits on its Phase-1 prefix (a few hundred
    /// characters of the article) until the app is force-quit. Driving the
    /// transition explicitly leaves a balanced begin/end pair and delivers the
    /// appearance the reparenting swallowed.
    private static func install(_ root: UIViewController, in window: UIWindow) {
        let wasReparented = root.parent != nil
        detachFromOnboardingParent(root)
        window.rootViewController = root
        window.makeKeyAndVisible()
        guard wasReparented else { return }
        root.beginAppearanceTransition(true, animated: false)
        root.endAppearanceTransition()
    }

    private static func detachFromOnboardingParent(_ root: UIViewController) {
        guard root.parent != nil else { return }
        root.willMove(toParent: nil)
        root.view.removeFromSuperview()
        root.removeFromParent()
        root.view.alpha = 1
    }
}

private extension UIViewController {
    func descendantNavigationController() -> UINavigationController? {
        if let navigation = self as? UINavigationController { return navigation }
        for child in children {
            if let navigation = child.descendantNavigationController() { return navigation }
        }
        return nil
    }
}

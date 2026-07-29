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
        guard let snapshot = window.snapshotView(afterScreenUpdates: true) else {
            window.rootViewController = root
            window.makeKeyAndVisible()
            OnboardingAnimationClock.restoreNormalSpeed(in: window)
            return
        }
        snapshot.frame = bounds

        window.rootViewController = root
        window.makeKeyAndVisible()
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

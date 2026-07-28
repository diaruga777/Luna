//
//  ReaderOnboardingWiring.swift
//  Luna
//
//  The app shell is compiled into every Luna surface, while the special
//  onboarding is selected only by KindWiring+Reader.  These closures keep the
//  shared SceneDelegate free of a Reader-only root decision.
//

import UIKit

enum ReaderOnboardingWiring {
    static var installLaunchTransition: ((UIWindow) -> Void)?
    static var makeCompletedRootViewController: (() -> UIViewController)?
}

protocol ReaderLaunchTransitionTarget: AnyObject {
    /// The resting center-card frame in window coordinates.
    func readerLaunchTargetFrame(in window: UIWindow) -> CGRect?
    func readerLaunchTransitionDidFinish()
}

extension ReaderLaunchTransitionTarget {
    func readerLaunchTransitionDidFinish() {}
}

extension UIViewController {
    func readerLaunchTransitionTarget() -> ReaderLaunchTransitionTarget? {
        if let target = self as? ReaderLaunchTransitionTarget { return target }
        if let presentedViewController,
           let target = presentedViewController.readerLaunchTransitionTarget() {
            return target
        }
        for child in children.reversed() {
            if let target = child.readerLaunchTransitionTarget() { return target }
        }
        return nil
    }
}

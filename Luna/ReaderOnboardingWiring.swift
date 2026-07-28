//
//  ReaderOnboardingWiring.swift
//  Luna
//
//  The app shell and onboarding engine are compiled into every Luna surface.
//  KindWiring supplies each target's root and demo-save implementation without
//  making the shared controller import unavailable feature modules.
//

import UIKit

enum ReaderOnboardingWiring {
    static var installLaunchTransition: ((UIWindow) -> Void)?
    static var makeCompletedRootViewController: (() -> UIViewController)?
    static var installTemporaryDemoSave: (() -> Void)?
    static var cleanupTemporaryDemoSave: (() -> Void)?
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

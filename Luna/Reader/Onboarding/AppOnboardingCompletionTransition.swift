//
//  AppOnboardingCompletionTransition.swift
//  Luna
//

import LunaDesignSystem
import UIKit

enum AppOnboardingCompletionTransition {
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
        root.view.alpha = 0
        root.descendantNavigationController()?.installLunarEclipseTransition()

        let target = root.appLaunchTransitionTarget()
        let targetFrame = target?.appLaunchTargetFrame(in: window)
            ?? AppLaunchGeometry.fallbackRootCardFrame(
                in: bounds,
                safeAreaInsets: window.safeAreaInsets)

        let stage = UIView(frame: bounds)
        stage.backgroundColor = .clear
        stage.isUserInteractionEnabled = false
        window.addSubview(stage)
        stage.addSubview(snapshot)

        let dimmer = UIView(frame: stage.bounds)
        dimmer.backgroundColor = .black
        dimmer.alpha = 0
        stage.addSubview(dimmer)

        let startFrame = targetFrame.offsetBy(dx: bounds.width + targetFrame.width, dy: 0)
        let corona = EclipseCoronaView(
            bodySize: targetFrame.size,
            cornerRadius: CardSurfaceView.cornerRadius,
            tint: LunaSurfacePalette.atmosphereTint)
        corona.frame = startFrame
        corona.alpha = 0.08
        stage.addSubview(corona)

        let flare = EclipseFlareView(frame: CGRect(
            x: targetFrame.minX - 65,
            y: targetFrame.midY - 65,
            width: 130,
            height: 130))
        flare.alpha = 0
        flare.transform = CGAffineTransform(scaleX: 0.45, y: 0.45)
        stage.addSubview(flare)

        let moon = CardSurfaceView(frame: startFrame)
        moon.backgroundColor = .black
        moon.setBorderEnabled(true)
        let black = UIView(frame: moon.bounds)
        black.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        black.backgroundColor = .black
        moon.installContentView(black)
        moon.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        stage.addSubview(moon)

        UIView.animateKeyframes(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0.18 : 0.58,
            delay: 0,
            options: [.calculationModeCubic, .beginFromCurrentState]
        ) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 1) {
                moon.frame = targetFrame
                moon.transform = CGAffineTransform(
                    scaleX: CardEclipseTransition.zenithScale,
                    y: CardEclipseTransition.zenithScale)
                corona.frame = targetFrame
                corona.alpha = 1
                dimmer.alpha = 0.94
            }
            UIView.addKeyframe(withRelativeStartTime: 0.76, relativeDuration: 0.24) {
                flare.alpha = 1
                flare.transform = .identity
                snapshot.alpha = 0
            }
        } completion: { _ in
            root.view.alpha = 1
            snapshot.removeFromSuperview()
            UIView.animateKeyframes(
                withDuration: UIAccessibility.isReduceMotionEnabled ? 0.16 : 0.38,
                delay: 0,
                options: [.calculationModeCubic, .beginFromCurrentState]
            ) {
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 1) {
                    dimmer.alpha = 0
                    corona.alpha = 0
                    moon.transform = .identity
                    moon.alpha = 0
                }
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.36) {
                    flare.alpha = 0
                    flare.transform = CGAffineTransform(scaleX: 1.35, y: 1.35)
                }
            } completion: { _ in
                stage.removeFromSuperview()
                target?.appLaunchTransitionDidFinish()
                OnboardingAnimationClock.restoreNormalSpeed(in: window)
            }
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

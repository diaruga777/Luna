//
//  AppOnboardingInfrastructure.swift
//  Luna
//

import QuartzCore
import LunaDesignSystem
import UIKit

/// Target-specific persistence behind the shared visual journey.
///
/// `install` returns false when the real save could not be created. The
/// onboarding marker is never written in that case, so a transient disk or
/// bundle failure cannot strand the user in an empty completed state.
struct OnboardingTemporarySave {
    let install: () -> Bool
    let cleanup: () -> Void
}

/// Everything the shared controller needs to cross into a target-specific root.
/// Keeping this immutable and injected avoids mutable process-wide closure slots.
struct AppOnboardingCompletion {
    let temporarySave: OnboardingTemporarySave
    let makeCompletedRootViewController: () -> UIViewController

    init(
        temporarySave: OnboardingTemporarySave,
        makeCompletedRootViewController: @escaping () -> UIViewController
    ) {
        self.temporarySave = temporarySave
        self.makeCompletedRootViewController = makeCompletedRootViewController
    }
}

/// Shared visual alignment for each stage of the first-run journey.
enum AppOnboardingLayout {
    static let contentTopRatio: CGFloat = 1 / 3

    static func contentTop(in bounds: CGRect) -> CGFloat {
        bounds.minY + bounds.height * contentTopRatio
    }
}

protocol AppLaunchTransitionTarget: AnyObject {
    /// The resting center-card frame in window coordinates.
    func appLaunchTargetFrame(in window: UIWindow) -> CGRect?
    /// The splash's crossfade into the live hierarchy is starting. The splash
    /// and the content beneath it are pixel-identical, so work that should
    /// read as immediate — the intro's first lunar reveal — starts here
    /// rather than waiting out the fade.
    func appLaunchTransitionWillReveal()
    func appLaunchTransitionDidFinish()
    var keepsOnboardingSlowMotionAfterLaunch: Bool { get }
    /// True when the live hierarchy under the splash is pixel-identical to it
    /// (incomplete onboarding), letting the launch crossfade collapse to the
    /// quickest possible reveal instead of the content-masking 0.20s fade.
    var prefersInstantLaunchReveal: Bool { get }
}

extension AppLaunchTransitionTarget {
    func appLaunchTransitionWillReveal() {}
    func appLaunchTransitionDidFinish() {}
    var keepsOnboardingSlowMotionAfterLaunch: Bool { false }
    var prefersInstantLaunchReveal: Bool { false }
}

extension UIViewController {
    func appLaunchTransitionTarget() -> AppLaunchTransitionTarget? {
        if let target = self as? AppLaunchTransitionTarget { return target }
        if let presentedViewController,
           let target = presentedViewController.appLaunchTransitionTarget() {
            return target
        }
        for child in children.reversed() {
            if let target = child.appLaunchTransitionTarget() { return target }
        }
        return nil
    }
}

/// Debug-only wall-clock scaling for close visual inspection.
///
/// The window layer slows every production Core Animation—including the real
/// card eclipse—while `delay(_:)` and `displayLinkDuration(_:)` keep explicit
/// timers and the custom liquid-wave renderer on the same timeline.
enum OnboardingAnimationClock {
    static let scale: Double = {
        #if DEBUG
        return resolvedScale(arguments: ProcessInfo.processInfo.arguments)
        #else
        return 1
        #endif
    }()

    static func resolvedScale(arguments: [String]) -> Double {
        if arguments.contains("-slowOnboardingAnimations") { return 6 }
        guard let flag = arguments.firstIndex(of: "-onboardingAnimationScale"),
              arguments.indices.contains(flag + 1),
              let value = Double(arguments[flag + 1])
        else { return 1 }
        return min(max(value, 1), 12)
    }

    static var isSlowed: Bool { scale > 1 }

    static func delay(_ base: TimeInterval) -> TimeInterval {
        base * scale
    }

    static func displayLinkDuration(_ base: CFTimeInterval) -> CFTimeInterval {
        base * scale
    }

    static func installSlowMotionIfRequested(in window: UIWindow) {
        guard isSlowed, window.layer.speed == 1 else { return }
        window.layer.speed = Float(1 / scale)
    }

    static func restoreNormalSpeed(in window: UIWindow) {
        guard window.layer.speed != 1 else { return }
        let pausedTime = window.layer.convertTime(CACurrentMediaTime(), from: nil)
        window.layer.speed = 1
        window.layer.timeOffset = 0
        window.layer.beginTime = 0
        let resumedTime = window.layer.convertTime(CACurrentMediaTime(), from: nil)
        window.layer.beginTime = resumedTime - pausedTime
    }
}

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
    let makeSavedCardContent: () -> CardContentViewController?
    let makeCompletedRootViewController: () -> UIViewController

    init(
        temporarySave: OnboardingTemporarySave,
        makeSavedCardContent: @escaping () -> CardContentViewController? = { nil },
        makeCompletedRootViewController: @escaping () -> UIViewController
    ) {
        self.temporarySave = temporarySave
        self.makeSavedCardContent = makeSavedCardContent
        self.makeCompletedRootViewController = makeCompletedRootViewController
    }
}

/// Target-neutral adapter for a real surface card supplied by one app's
/// composition root. The shared onboarding target can mount it without linking
/// that surface's feature module into the other standalone apps.
final class OnboardingEmbeddedCardContentViewController:
    CardContentViewController
{
    private let embedded: UIViewController
    private let onCentered: () -> Void

    init(
        embedded: UIViewController,
        onCentered: @escaping () -> Void = {}
    ) {
        self.embedded = embedded
        self.onCentered = onCentered
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        addChild(embedded)
        embedded.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(embedded.view)
        embedded.didMove(toParent: self)
        NSLayoutConstraint.activate([
            embedded.view.topAnchor.constraint(equalTo: view.topAnchor),
            embedded.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            embedded.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            embedded.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func cardDidBecomeCentered() {
        super.cardDidBecomeCentered()
        onCentered()
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
    func appLaunchTransitionDidFinish()
    var keepsOnboardingSlowMotionAfterLaunch: Bool { get }
}

extension AppLaunchTransitionTarget {
    func appLaunchTransitionDidFinish() {}
    var keepsOnboardingSlowMotionAfterLaunch: Bool { false }
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

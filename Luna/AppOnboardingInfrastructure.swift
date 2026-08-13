//
//  AppOnboardingInfrastructure.swift
//  Luna
//

import QuartzCore
import LunaDesignSystem
import LunaStorage
import UIKit

/// How the shared journey notices a REAL save arriving while it is on screen —
/// a share/action extension or an App Intent writing to the store behind the
/// intro card, which completes onboarding around that item.
///
/// **Onboarding itself never writes.** The mock Safari page and the mock
/// Messages conversation render their article/video/tracker entirely inside
/// their own replica views; no demonstration item is stored, not even for the
/// length of a lesson, so every id this reports is content the user really
/// saved — see `claudedocs/reader-onboarding.md`.
struct OnboardingContentWatch {
    /// Every notification this app's content stores post when their contents
    /// change. Each app names its own: a foreign kind's notification lives in a
    /// module that app doesn't link.
    let changeNotifications: [Notification.Name]
    /// What is stored across every store this app saves into. A protocol rather
    /// than a closure because this is per-app composition — each app's stores are
    /// a different set — not a value describing one row.
    let content: any OnboardingStoredContentProviding

    init(
        changeNotifications: [Notification.Name] = [.readingListChanged],
        content: any OnboardingStoredContentProviding = ReadingListStoredContent()
    ) {
        self.changeNotifications = changeNotifications
        self.content = content
    }
}

/// The ids currently stored across every store an app saves into — how the
/// journey notices a real save landing behind it.
protocol OnboardingStoredContentProviding {
    func storedIdentifiers() -> Set<UUID>
}

/// The universal answer: the shared reading list. Apps whose kinds live in a
/// second store compose their own.
struct ReadingListStoredContent: OnboardingStoredContentProviding {
    func storedIdentifiers() -> Set<UUID> {
        Set(ReadingListStore.shared.items().map(\.id))
    }
}

/// Takes out a demonstration item an OLDER build installed.
///
/// Builds up to this one saved the mock article/video/tracker into the shared
/// store so the deck behind a lesson wasn't empty, and swept it at the next
/// launch. An install updating across that change can still be holding one, so
/// each app sweeps its own marker once at launch. Nothing writes one any more:
/// this is migration only, and can be deleted once no install in the field
/// predates the change.
protocol OnboardingLegacyDemoSweeping {
    /// Deletes the demonstration item a previous build recorded, and clears the
    /// marker either way. Ownership is by exact id, so a save the user made
    /// themselves is never touched.
    func sweepLegacyDemoSave()
}

/// Builds this target's post-onboarding root — the card deck, per app.
@MainActor
protocol CompletedOnboardingRootMaking {
    func makeCompletedRootViewController() -> UIViewController
}

/// The production root: whichever `KindWiring` variant this target compiles.
@MainActor
struct KindWiringOnboardingRoot: CompletedOnboardingRootMaking {
    func makeCompletedRootViewController() -> UIViewController {
        KindWiring.makeRootViewController()
    }
}

/// Everything the shared controller needs to cross into a target-specific root.
/// Keeping this immutable and injected avoids mutable process-wide closure slots.
struct AppOnboardingCompletion {
    let contentWatch: OnboardingContentWatch
    let root: any CompletedOnboardingRootMaking

    init(
        contentWatch: OnboardingContentWatch = OnboardingContentWatch(),
        root: any CompletedOnboardingRootMaking
    ) {
        self.contentWatch = contentWatch
        self.root = root
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

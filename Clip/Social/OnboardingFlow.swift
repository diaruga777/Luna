//
//  OnboardingFlow.swift
//  Clip
//

import ClipSocial
import ClipModels
import UIKit

/// Builds the first-launch onboarding: pick a username, then quick steps to
/// enable notifications, install the Safari extension, and set up the
/// save-page shortcut / Action Button. Each step can be skipped.
enum OnboardingFlow {

    /// Returns the onboarding root (a bare navigation controller). `onFinished`
    /// runs after the last step.
    static func make(onFinished: @escaping () -> Void) -> UIViewController {
        let nav = UINavigationController()
        nav.setNavigationBarHidden(true, animated: false)

        let username = OnboardingViewController { [weak nav] in
            guard let nav else { return }
            nav.pushViewController(notificationsStep(nav: nav, onFinished: onFinished), animated: true)
        }
        nav.viewControllers = [username]
        return nav
    }

    /// Re-runs ONLY the device-setup steps (notifications, Safari extension,
    /// shortcut) — not the username/identity step, which would create a new
    /// identity and orphan existing friends. Used by the Settings "Replay
    /// Setup" button.
    static func makeSetupOnly(onFinished: @escaping () -> Void) -> UIViewController {
        let nav = UINavigationController()
        nav.setNavigationBarHidden(true, animated: false)
        nav.viewControllers = [notificationsStep(nav: nav, onFinished: onFinished)]
        return nav
    }

    #if DEBUG
    /// Standalone, ordered onboarding step view controllers for snapshot/navigation
    /// tests. These are the same screens the flow pushes, built without the
    /// inter-step navigation wiring so each can be rendered in isolation. Index 0 is
    /// the username step; the rest are the device-setup steps in flow order.
    static func stepViewControllersForTesting() -> [UIViewController] {
        let nav = UINavigationController()
        var steps: [UIViewController] = [OnboardingViewController(onComplete: {})]
        steps.append(notificationsStep(nav: nav, onFinished: {}))
        if #available(iOS 27.0, *) {
            steps.append(safariStep(nav: nav, onFinished: {}))
            steps.append(shortcutStep(nav: nav, onFinished: {}))
        }
        steps.append(actionExtensionStep(onFinished: {}))
        return steps
    }
    #endif

    private static func notificationsStep(
        nav: UINavigationController, onFinished: @escaping () -> Void
    ) -> UIViewController {
        // The Safari extension + Action Button save flow needs iOS 27+; on older
        // versions, notifications is the last step.
        let proceed: () -> Void = { [weak nav] in
            if #available(iOS 27.0, *) {
                nav?.pushViewController(safariStep(nav: nav, onFinished: onFinished), animated: true)
            } else {
                nav?.pushViewController(actionExtensionStep(onFinished: onFinished), animated: true)
            }
        }
        return OnboardingStepViewController(
            symbol: "bell.badge",
            title: "Get notified",
            body: "Enable to get a notification when a friend shares an article with you.",
            primary: .init(title: "Enable Notifications") { _ in
                NotificationManager.requestAuthorization()
                UIApplication.shared.registerForRemoteNotifications()
                proceed()
            },
            continueTitle: "Not Now",
            animation: .notification,
            onContinue: proceed)
    }

    private static func safariStep(
        nav: UINavigationController?, onFinished: @escaping () -> Void
    ) -> UIViewController {
        OnboardingStepViewController(
            symbol: "safari",
            title: "Save any Safari page instantly",
            body: "Queue remembers your last visited site. Visit data stays on device and is never shared.\n\nTurn on the Queue extension in Settings → Apps → Safari → Extensions.",
            primary: .init(title: "Open Settings") { _ in SystemSettingsLink.open() },
            continueTitle: "Continue",
            animation: .settingsToggle,
            onContinue: { [weak nav] in
                nav?.pushViewController(shortcutStep(nav: nav, onFinished: onFinished), animated: true)
            })
    }

    private static func shortcutStep(nav: UINavigationController?, onFinished: @escaping () -> Void) -> UIViewController {
        OnboardingStepViewController(
            symbol: "bolt.badge.clock",
            title: "Save anything, instantly",
            body: "Press the Action Button to save what's on your screen.\n\nAssign our customizable shortcut to your Action Button:Settings → Action Button → Shortcut → \"\(BundledShortcut.displayName)\".",
            primary: .init(title: "Install Shortcut") { step in
                BundledShortcut.presentInstaller(from: step)
            },
            secondary: .init(title: "Open Settings") { _ in SystemSettingsLink.open() },
            continueTitle: "Continue",
            animation: .actionButton,
            onContinue: { [weak nav] in
                nav?.pushViewController(actionExtensionStep(onFinished: onFinished), animated: true)
            })
    }

    /// Final step: how the Share-sheet "Read in Queue" action extension works.
    private static func actionExtensionStep(onFinished: @escaping () -> Void) -> UIViewController {
        OnboardingStepViewController(
            symbol: "square.and.arrow.up",
            title: "Share to your Queue",
            body: "Send in anything to read instantly!\n\nTap \"Edit Actions\" and add Queue to favorites to make it even easier.",
            primary: nil,
            continueTitle: "Done",
            animation: .actionExtension,
            onContinue: onFinished)
    }

}

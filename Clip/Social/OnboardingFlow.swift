//
//  OnboardingFlow.swift
//  Clip
//

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

    private static func notificationsStep(
        nav: UINavigationController, onFinished: @escaping () -> Void
    ) -> UIViewController {
        // The Safari extension + Action Button save flow needs iOS 27+; on older
        // versions, notifications is the last step.
        let proceed: () -> Void = { [weak nav] in
            if #available(iOS 27.0, *) {
                nav?.pushViewController(safariStep(nav: nav, onFinished: onFinished), animated: true)
            } else {
                onFinished()
            }
        }
        return OnboardingStepViewController(
            symbol: "bell.badge",
            title: "Stay in the Loop",
            body: "Get a notification the moment a friend shares an article with you.",
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
            title: "Save from Safari",
            body: "Everything stays on device. The app remembers your last visited site so it can be saved instantly.\n\nTurn on the Click extension in Settings → Apps → Safari → Extensions.",
            primary: .init(title: "Open Settings") { _ in SystemSettingsLink.open() },
            continueTitle: "Continue",
            animation: .settingsToggle,
            onContinue: { [weak nav] in
                nav?.pushViewController(shortcutStep(onFinished: onFinished), animated: true)
            })
    }

    private static func shortcutStep(onFinished: @escaping () -> Void) -> UIViewController {
        OnboardingStepViewController(
            symbol: "bolt.badge.clock",
            title: "One-Press Saving",
            body: "Install the shortcut, then assign it to your Action Button to save the page you're reading instantly:\n\nSettings → Action Button → Shortcut → \"Clip Safari Page\".",
            primary: .init(title: "Install Shortcut") { step in
                installShortcut(from: step)
            },
            secondary: .init(title: "Open Settings") { _ in SystemSettingsLink.open() },
            continueTitle: "Done",
            animation: .actionButton,
            onContinue: onFinished)
    }

    /// Shares the bundled signed shortcut to the Shortcuts app (one-tap import).
    private static func installShortcut(from presenter: UIViewController) {
        guard let bundled = Bundle.main.url(
            forResource: "Clip Safari Page", withExtension: "shortcut")
        else { return }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("Clip Safari Page.shortcut")
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.copyItem(at: bundled, to: tmp)
        let activity = UIActivityViewController(activityItems: [tmp], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = presenter.view
        presenter.present(activity, animated: true)
    }
}

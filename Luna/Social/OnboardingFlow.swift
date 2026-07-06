//
//  OnboardingFlow.swift
//  Luna
//

import LunaSocialUI
import LunaSocial
import LunaMailAccount
import LunaTransitions
import UIKit

/// Builds the first-launch onboarding: a skippable email-account step, then
/// quick steps to install the Safari extension and set up the relevant save
/// action. Each step can be skipped.
public enum OnboardingFlow {

    /// Returns the onboarding root (a bare navigation controller). `onFinished`
    /// runs after the last step.
    public static func make(onFinished: @escaping () -> Void) -> UIViewController {
        let nav = UINavigationController()
        nav.setNavigationBarHidden(true, animated: false)
        nav.installDotMatrixTransitions()
        if EmailAccountStore.shared.isConfigured, let account = EmailAccountStore.shared.account {
            nav.viewControllers = [existingAccountStep(accountAddress: account.address, onFinished: onFinished)]
        } else {
            nav.viewControllers = [emailStep(nav: nav, onFinished: onFinished)]
        }
        return nav
    }

    /// Email, Safari extension, and one final save-action setup screen.
    private static let totalSteps = 3

    #if DEBUG
    /// Standalone, ordered onboarding step view controllers for snapshot/navigation
    /// tests, built without the inter-step navigation wiring.
    public static func stepViewControllersForTesting() -> [UIViewController] {
        let nav = UINavigationController()
        var steps: [UIViewController] = [emailStep(nav: nav, onFinished: {})]
        steps.append(safariStep(nav: nav, onFinished: {}))
        if #available(iOS 27.0, *) {
            steps.append(shortcutStep(nav: nav, onFinished: {}))
        } else {
            steps.append(actionExtensionStep(onFinished: {}))
        }
        return steps
    }
    #endif

    /// Skippable step: connect an email account (drives send + receive of shares).
    private static func emailStep(
        nav: UINavigationController, onFinished: @escaping () -> Void
    ) -> UIViewController {
        let proceed: () -> Void = { [weak nav] in
            guard let nav else { return }
            nav.pushViewController(safariStep(nav: nav, onFinished: onFinished), animated: true)
        }
        return OnboardingStepViewController(
            symbol: "envelope.badge",
            title: "Connect your email",
            body: "Luna sends and receives shared articles through your own email account. "
                + "Connect it now, or set it up later — you'll see a reminder in your reading list.",
            primary: .init(title: "Set Up Email") { step in
                EmailLoginFlow.present(from: step) { _ in proceed() }
            },
            continueTitle: "Skip",
            animation: nil,
            progress: .init(index: 0, total: totalSteps),
            onContinue: proceed)
    }

    private static func existingAccountStep(
        accountAddress: String, onFinished: @escaping () -> Void
    ) -> UIViewController {
        return OnboardingStepViewController(
            symbol: "envelope.badge.fill",
            title: "Email already connected",
            body: "Luna is already signed in as \(accountAddress). Finish setup to use this app with the same on-device library and account.",
            primary: nil,
            continueTitle: "Finish",
            animation: nil,
            progress: nil,
            onContinue: {
                NotificationManager.requestAuthorization()
                onFinished()
            })
    }

    private static func safariStep(
        nav: UINavigationController?, onFinished: @escaping () -> Void
    ) -> UIViewController {
        OnboardingStepViewController(
            symbol: "safari",
            title: "Unlock and save from Safari",
            body: "Turn on the Luna Safari extension to unlock supported articles automatically and add a save button on the page.\n\nYour browsing and saved article data stays on this device.",
            primary: .init(title: "Open Settings") { _ in SystemSettingsLink.open() },
            continueTitle: "Continue",
            animation: .settingsToggle,
            progress: .init(index: 1, total: totalSteps),
            onContinue: { [weak nav] in
                if #available(iOS 27.0, *) {
                    nav?.pushViewController(shortcutStep(nav: nav, onFinished: onFinished), animated: true)
                } else {
                    nav?.pushViewController(actionExtensionStep(onFinished: onFinished), animated: true)
                }
            })
    }

    private static func shortcutStep(nav: UINavigationController?, onFinished: @escaping () -> Void) -> UIViewController {
        OnboardingStepViewController(
            symbol: "bolt.badge.clock",
            title: "Save anything, instantly",
            body: "Press the Action Button to save what's on your screen.\n\nAssign our customizable shortcut to your Action Button: Settings → Action Button → Shortcut → \"\(BundledShortcut.displayName)\".",
            primary: .init(title: "Install Shortcut") { step in
                BundledShortcut.presentInstaller(from: step)
            },
            secondary: .init(title: "Open Settings") { _ in SystemSettingsLink.open() },
            continueTitle: "Done",
            animation: .actionButton,
            progress: .init(index: 2, total: totalSteps),
            onContinue: onFinished)
    }

    /// Final step: how the Share-sheet "Read in Luna" action extension works.
    private static func actionExtensionStep(onFinished: @escaping () -> Void) -> UIViewController {
        OnboardingStepViewController(
            symbol: "square.and.arrow.up",
            title: "Share to your Luna",
            body: "Send in anything to read instantly!\n\nTap \"Edit Actions\" and add Luna to favorites to make it even easier.",
            primary: nil,
            continueTitle: "Done",
            animation: .actionExtension,
            progress: .init(index: totalSteps - 1, total: totalSteps),
            onContinue: onFinished)
    }
}

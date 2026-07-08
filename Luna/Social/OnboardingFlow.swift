//
//  OnboardingFlow.swift
//  Luna
//

import LunaSocialUI
import LunaSocial
import LunaMailAccount
import LunaStorage
import LunaTransitions
import UIKit

/// Builds the first-launch onboarding: a skippable email-account step, then quick
/// steps to enable the Safari extension and set up the relevant save action
/// (Action Button shortcut on iOS 27+, or the Share-sheet action extension pre-27).
/// Each step can be skipped.
public enum OnboardingFlow {

    /// Returns the onboarding root (a bare navigation controller). `onFinished`
    /// runs after the last step. `stores` defaults to the app's real, persisted
    /// stores; Settings → "Replay Onboarding" passes `.ephemeral()` instead so the
    /// replay can sandbox account/Safari writes while temporarily re-arming the
    /// Action Button state machine for lifecycle and App Intent callbacks.
    public static func make(
        stores: OnboardingStores = .real, onFinished: @escaping () -> Void
    ) -> UIViewController {
        let nav = UINavigationController()
        nav.setNavigationBarHidden(true, animated: false)
        // Deliberately NOT installing the Dot Matrix pixel-wipe here. Each onboarding
        // step carries a dense, continuously-animating dot-matrix backdrop, and the
        // wipe's `drawHierarchy(afterScreenUpdates: true)` snapshot of the incoming
        // step forces a synchronous render-server commit of that whole backdrop —
        // which stalled the step-to-step push by ~3 s on device. A plain UIKit push
        // takes no snapshot, so onboarding transitions stay instant.
        if stores.emailAccountStore.isConfigured, let account = stores.emailAccountStore.account {
            nav.viewControllers = [existingAccountStep(
                stores: stores, accountAddress: account.address, onFinished: onFinished)]
        } else {
            nav.viewControllers = [emailStep(stores: stores, nav: nav, onFinished: onFinished)]
        }
        return nav
    }

    /// Email, Safari extension, and — on iOS 27+, once the extension has run — an
    /// Action Button shortcut install + setup pair; pre-27 (or if Safari still
    /// hasn't reported that the extension ran) uses a single final action-extension
    /// step instead. 4 steps on iOS 27+, 3 otherwise.
    private static var totalSteps: Int {
        if #available(iOS 27.0, *) { return 4 }
        return 3
    }

    /// This app's per-surface storage key (`"reader"` / `"downloader"` /
    /// `"pricetracker"`) — every onboarding store below is keyed by it.
    private static var surface: String { AppSurfaceConfig.current.storageIdentifier }

    #if DEBUG
    /// Cross-image-safe stand-in for `viewController is OnboardingStepViewController`
    /// in tests. The test bundle statically embeds its own copy of the LunaSocialUI
    /// classes alongside the app's (objc logs "implemented in both … may cause
    /// spurious casting failures"), so an `is` check compiled into the TEST image can
    /// spuriously fail against instances created by the app image. This helper runs
    /// the check in the app image — the same copy `make` builds the steps from.
    public static func isOnboardingStep(_ viewController: UIViewController?) -> Bool {
        viewController is OnboardingStepViewController
    }

    /// Standalone, ordered onboarding step view controllers for snapshot/navigation
    /// tests, built without the inter-step navigation wiring. Includes every step
    /// kind (the Action Button pair is only reachable at runtime on iOS 27+, but the
    /// factories themselves have no availability requirement, so they're still
    /// buildable — and worth snapshotting — on any OS).
    public static func stepViewControllersForTesting() -> [UIViewController] {
        let nav = UINavigationController()
        let stores = OnboardingStores.real
        var steps: [UIViewController] = [emailStep(stores: stores, nav: nav, onFinished: {})]
        steps.append(safariStep(stores: stores, nav: nav, onFinished: {}))
        steps.append(shortcutInstallStep(stores: stores, nav: nav, onFinished: {}))
        steps.append(actionButtonStep(stores: stores, onFinished: {}))
        steps.append(actionExtensionStep(onFinished: {}))
        return steps
    }
    #endif

    /// Skippable step: connect an email account (drives send + receive of shares).
    private static func emailStep(
        stores: OnboardingStores, nav: UINavigationController, onFinished: @escaping () -> Void
    ) -> UIViewController {
        let proceed: () -> Void = { [weak nav] in
            guard let nav else { return }
            nav.pushViewController(safariStep(stores: stores, nav: nav, onFinished: onFinished), animated: true)
        }
        return OnboardingStepViewController(
            symbol: "envelope.badge",
            title: "Connect your email",
            body: "Luna sends and receives shared articles through your own email account. "
                + "Connect it now, or set it up later — you'll see a reminder in your reading list.",
            primary: .init(title: "Set Up Email") { step in
                EmailLoginFlow.present(from: step, accountStore: stores.emailAccountStore) { _ in proceed() }
            },
            continueTitle: "Skip",
            animation: nil,
            progress: .init(index: 0, total: totalSteps),
            onContinue: proceed)
    }

    private static func existingAccountStep(
        stores: OnboardingStores, accountAddress: String, onFinished: @escaping () -> Void
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

    /// Enable the Safari extension. Sending the user to Safari is a real
    /// backgrounding round-trip (unlike the in-app Settings deep links elsewhere in
    /// this flow), so this step drives a PiP guide video and reacts to both the
    /// extension's own "it's enabled" hand-off (`SafariExtensionStatusStore`) and a
    /// plain foreground/Continue tap.
    private static func safariStep(
        stores: OnboardingStores, nav: UINavigationController?, onFinished: @escaping () -> Void
    ) -> UIViewController {
        let guide = OnboardingGuideVideo(resourceName: "SafariExtensionGuide")
        var didAdvance = false

        let advance: () -> Void = { [weak nav] in
            guard !didAdvance else { return }
            didAdvance = true
            stores.setSafariTakeoverPending(false, forSurface: surface)
            guide.stopPictureInPicture()
            guard let nav else { return }
            if #available(iOS 27.0, *), stores.shouldUseActionButtonFlowAfterSafari(forSurface: surface) {
                nav.pushViewController(
                    shortcutInstallStep(stores: stores, nav: nav, onFinished: onFinished), animated: true)
            } else {
                nav.pushViewController(actionExtensionStep(onFinished: onFinished), animated: true)
            }
        }

        let step = OnboardingStepViewController(
            symbol: "safari",
            title: "Unlock and save from Safari",
            body: "Turn on the Luna Safari extension to unlock supported articles and add a save button on the page.\n\n"
                + "In Safari's \u{201c}aA\u{201d} menu, choose Manage Extensions and turn Luna on.",
            primary: .init(title: "Open Safari") { _ in
                stores.setSafariTakeoverPending(true, forSurface: surface)
                guide.startPictureInPicture()
                if let url = URL(string: "https://en.wikipedia.org/wiki/Wikipedia") {
                    UIApplication.shared.open(url)
                }
            },
            continueTitle: "Continue",
            animation: .safariExtension,
            progress: .init(index: 1, total: totalSteps),
            onContinue: advance)

        step.onDidAppear = { [weak step] in
            stores.setSafariTakeoverPending(true, forSurface: surface)
            guide.play()
            if let step { step.installBackdropView(guide.playerView) }
        }
        step.onWillEnterForeground = {
            guide.stopPictureInPicture()
            if stores.isSafariExtensionEnabled(forSurface: surface) {
                advance()
            }
        }
        return step
    }

    /// iOS 27+ happy path, step 1 of 2: import the bundled Action Button shortcut.
    private static func shortcutInstallStep(
        stores: OnboardingStores, nav: UINavigationController?, onFinished: @escaping () -> Void
    ) -> UIViewController {
        var didAdvance = false
        var stateObserver: NSObjectProtocol?

        let advance: () -> Void = { [weak nav] in
            guard !didAdvance else { return }
            didAdvance = true
            if let stateObserver {
                NotificationCenter.default.removeObserver(stateObserver)
            }
            guard let nav else { return }
            nav.pushViewController(actionButtonStep(stores: stores, onFinished: onFinished), animated: true)
        }

        let step = OnboardingStepViewController(
            symbol: "square.and.arrow.down.on.square",
            title: "Save anything, instantly",
            body: "Import \u{201c}\(BundledShortcut.displayName)\u{201d} into Shortcuts — you'll assign it to your Action Button next.",
            primary: .init(title: "Install Shortcut") { step in
                stores.beginActionButtonInstallStep(forSurface: surface)
                BundledShortcut.presentInstaller(from: step)
            },
            continueTitle: "Continue",
            animation: .shortcutInstall,
            progress: .init(index: 2, total: totalSteps),
            onContinue: {
                stores.setActionButtonState(.actionButtonSetup, forSurface: surface)
                advance()
            })

        step.onDidAppear = { [weak step] in
            if let stateObserver {
                NotificationCenter.default.removeObserver(stateObserver)
            }
            // Observe unfiltered and match the surface in-handler: NotificationCenter
            // matches `object` by identity, which is unreliable for bridged strings.
            stateObserver = NotificationCenter.default.addObserver(
                forName: ActionButtonOnboardingStore.stateDidChangeNotification,
                object: nil, queue: .main
            ) { notification in
                guard notification.object as? String == surface else { return }
                guard let step, step.navigationController?.topViewController === step else { return }
                if stores.actionButtonState(forSurface: surface) == .actionButtonSetup {
                    advance()
                }
            }
        }
        step.onWillEnterForeground = { [weak step] in
            guard let step, step.navigationController?.topViewController === step else { return }
            if stores.actionButtonState(forSurface: surface) == .actionButtonSetup {
                advance()
            }
        }
        return step
    }

    /// iOS 27+ happy path, step 2 of 2: assign the shortcut to the Action Button.
    /// The intent may complete this step's job (`.done`) from the Shortcuts round
    /// trip itself — either while Luna is already frontmost (the state-change
    /// notification fires immediately, in-process) or right as the Shortcut
    /// relaunches Luna into the foreground (the notification, posted just before
    /// relaunch, is still observed by this same still-alive process) — so both
    /// orderings are covered by the one notification observer.
    private static func actionButtonStep(
        stores: OnboardingStores, onFinished: @escaping () -> Void
    ) -> UIViewController {
        let guide = OnboardingGuideVideo(resourceName: "ActionButtonGuide")
        var didFinish = false
        var stateObserver: NSObjectProtocol?

        let finish: () -> Void = {
            guard !didFinish else { return }
            didFinish = true
            if let stateObserver {
                NotificationCenter.default.removeObserver(stateObserver)
            }
            stores.setActionButtonState(.done, forSurface: surface)
            guide.stopPictureInPicture()
            onFinished()
        }

        let step = OnboardingStepViewController(
            symbol: "button.horizontal.top.press",
            title: "Set your Action Button",
            body: "Open Settings → Action Button, swipe to \u{201c}Shortcut,\u{201d} and choose \u{201c}\(BundledShortcut.displayName).\u{201d}",
            primary: .init(title: "Open Settings") { _ in
                stores.markActionButtonSettingsDeeplinkTapped(forSurface: surface)
                guide.startPictureInPicture()
                SystemSettingsLink.openActionButton()
            },
            continueTitle: "Done",
            animation: .actionButton,
            progress: .init(index: 3, total: totalSteps),
            onContinue: finish)

        step.onDidAppear = { [weak step] in
            if stores.actionButtonState(forSurface: surface) == .done {
                finish()
                return
            }
            guide.play()
            if let step { step.installBackdropView(guide.playerView) }
            if let stateObserver {
                NotificationCenter.default.removeObserver(stateObserver)
            }
            // Observe unfiltered and match the surface in-handler: NotificationCenter
            // matches `object` by identity, which is unreliable for bridged strings.
            stateObserver = NotificationCenter.default.addObserver(
                forName: ActionButtonOnboardingStore.stateDidChangeNotification,
                object: nil, queue: .main
            ) { notification in
                guard notification.object as? String == surface else { return }
                guard let step, step.navigationController?.topViewController === step else { return }
                if stores.actionButtonState(forSurface: surface) == .done {
                    finish()
                }
            }
        }
        step.onWillEnterForeground = { [weak step] in
            guide.stopPictureInPicture()
            let state = stores.actionButtonState(forSurface: surface)
            if state == .done {
                finish()
            } else if state == .awaitingActionButton {
                step?.updateBody("Press the Action Button to continue.")
            }
        }
        return step
    }

    /// Pre-27 (or Safari-not-yet-enabled) final step: how the Share-sheet "Save to Luna"
    /// action extension works.
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

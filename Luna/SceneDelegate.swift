//
//  SceneDelegate.swift
//  Luna
//
//  Luna is a weblink reader: save links from Safari (via the bundled Safari
//  extension + action-button shortcut), then read them in a scrolling reader
//  or an RSVP speed reader. Articles can be shared with friends by email and
//  sent to a Kindle.
//

import LunaReadingListUI
import LunaSocialUI
import LunaReadingList
import LunaArchiveReader
import LunaDesignSystem
import LunaStorage
import LunaURLClassification
import LunaSend
import LunaMediaDownload
import LunaInteropUI
import LunaTransitions
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    /// Per-app (private defaults) flag: each Luna app shows onboarding once.
    /// Shared with AppDelegate (notification-authorization gating).
    static let onboardingCompleteKey = "hasCompletedOnboarding"

    var window: UIWindow?

    /// A `lunareader://read` article URL that arrived before the main UI was up.
    private var pendingReadURL: String?
    /// A purchase hand-off that arrived while onboarding still owned the root.
    /// Consumed once the main navigation controller exists.
    private var pendingInteropRoute = false
    /// Set when a tapped pending-request notification asks to open that screen.
    /// Static because the tap is delivered to the AppDelegate before any scene
    /// may have connected.
    private static var pendingRequestsRoute = false

    /// Entry point for a tapped pending-request notification (called from
    /// `AppDelegate.userNotificationCenter(_:didReceive:)`). Opens the Pending
    /// Requests screen now if the UI is ready, else stashes it for when it is.
    static func routeToPendingRequests() {
        pendingRequestsRoute = true
        activeSceneDelegate()?.applyPendingNotificationRoute()
    }

    private static func activeSceneDelegate() -> SceneDelegate? {
        UIApplication.shared.connectedScenes.compactMap { $0.delegate as? SceneDelegate }.first
    }

    /// The main navigation controller, whichever shape the root takes: wrapped
    /// in the audio mini-player host (the normal main UI) or bare (UI-test and
    /// debug roots). Nil during onboarding.
    private var mainNavigationController: UINavigationController? {
        if let host = window?.rootViewController as? MiniPlayerHostViewController {
            return host.contentNavigationController
        }
        return window?.rootViewController as? UINavigationController
    }

    /// Wraps the main nav controller in the window-level audio mini-player
    /// host (claudedocs/audio-playback-plan.md, Phase 3): the bar floats above
    /// the bottom safe area, survives every push/pop, and hides while idle.
    ///
    /// READER SURFACE ONLY. Read-aloud is a Luna Reader feature, so only Reader
    /// wraps its nav controller in the mini-player host — the Downloader and
    /// Price Tracker apps install a bare nav controller and never carry the
    /// audio-playback bar or its interactions. (`mainNavigationController`
    /// already resolves either shape.)
    private func makeMainRootViewController() -> UIViewController {
        let surface = AppSurfaceConfig.current
        let root: UIViewController
        switch surface {
        case .all: root = ArticleCardsViewController()
        case .downloader: root = SavedMediaCardsViewController()
        case .reader: root = ArticleCardsViewController()
        case .priceTracker: root = ReadingListViewController(surface: surface)
        }
        let nav = UINavigationController(rootViewController: root)
        guard surface == .reader || surface == .all else { return nav }
        return MiniPlayerHostViewController(content: nav)
    }

    /// Pushes the Pending Requests screen onto the reading-list nav once the main
    /// UI exists.
    private func applyPendingNotificationRoute() {
        guard Self.pendingRequestsRoute,
              let nav = mainNavigationController else { return }
        Self.pendingRequestsRoute = false
        nav.dismiss(animated: false)
        nav.popToRootViewController(animated: false)
        nav.pushViewController(PendingRequestsViewController(), animated: true)
    }

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        AppearanceSettings.apply(to: window)

        // DEBUG-only UI-test seeding (no-op unless launched with `-uiTestState`).
        UITestSeeder.applyIfNeeded()
        if let rootForUITest = uiTestRootViewController() {
            window.rootViewController = rootForUITest
            self.window = window
            window.makeKeyAndVisible()
            return
        }

        #if DEBUG
        if let archiveArg = debugLaunchArgValue(after: "-openArchive"),
           let archiveURL = URL(string: archiveArg) {
            let item = ReadingListStore.shared.addIfAbsent(urlString: archiveURL.absoluteString)
                ?? ReadingListStore.shared.add(urlString: archiveURL.absoluteString)
            let reader = ArchiveWebReaderViewController(articleURL: archiveURL, itemID: item.id)
            window.rootViewController = UINavigationController(rootViewController: reader)
            self.window = window
            window.makeKeyAndVisible()
            return
        }
        #endif

        // All three apps onboard once (per-app flag). Onboarding includes a
        // skippable email-account step; email sharing is universal across apps.
        if !UserDefaults.standard.bool(forKey: Self.onboardingCompleteKey) {
            let finish: () -> Void = { [weak self] in
                UserDefaults.standard.set(true, forKey: Self.onboardingCompleteKey)
                self?.showMainUI()
                if let articleURL = self?.pendingReadURL {
                    self?.pendingReadURL = nil
                    self?.openReader(articleURL: articleURL)
                }
                self?.applyPendingInteropRoute()
                self?.applyPendingNotificationRoute()
            }
            window.rootViewController = OnboardingFlow.make(onFinished: finish)
        } else {
            window.rootViewController = makeMainRootViewController()
        }
        self.window = window
        window.makeKeyAndVisible()
        mainNavigationController?.installLunarEclipseTransition()

        if let url = connectionOptions.urlContexts.first?.url {
            route(url)
        }
        applyPendingNotificationRoute()
    }

    #if DEBUG
    /// Value following `flag` in the launch arguments (`-flag value`), or nil.
    private func debugLaunchArgValue(after flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    #endif

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        route(url)
    }

    /// Dispatches an incoming URL: a `<luna scheme>://read` link opens the reader;
    /// this app's own `<scheme>://interop` opens its StoreKit paywall.
    private func route(_ url: URL) {
        if LunaDeepLink.isOwnInteropLink(url) {
            pendingInteropRoute = true
            applyPendingInteropRoute()
            return
        }
        if LunaDeepLink.isRescueLink(url) {
            // The extension handoff wrote the URL + hint + consent into the shared
            // store; just drain it (pop to root first so the list is visible when a
            // rescued item flips ready). The coordinator also drains on foreground,
            // so this works even if the responder-chain open silently failed.
            mainNavigationController?.popToRootViewController(animated: false)
            URLRescueCoordinator.shared.drainPendingRequests()
            return
        }
        if let scheme = url.scheme, LunaDeepLink.allSchemes.contains(scheme),
           url.host == "settings", url.path == "/photos" {
            if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(settingsURL)
            }
            return
        }
        if let articleURL = LunaDeepLink.articleURL(from: url) {
            openReader(articleURL: articleURL)
        }
    }

    /// Opens the interoperability paywall once the main UI exists. Keeping the
    /// flag set while onboarding is visible makes a cold extension hand-off
    /// reliable; warm links consume it immediately. Pop/dismiss first so repeated
    /// hand-offs cannot stack duplicate paywalls over an unrelated flow.
    private func applyPendingInteropRoute() {
        guard pendingInteropRoute, let nav = mainNavigationController else { return }
        pendingInteropRoute = false
        nav.dismiss(animated: false)
        nav.popToRootViewController(animated: false)
        nav.pushViewController(InteropPaywallViewController(), animated: true)
    }

    /// Saves the article (if new), then opens it the way tapping its list row does.
    /// Stashes the URL if the main UI isn't up yet (onboarding).
    private func openReader(articleURL: String) {
        guard let nav = mainNavigationController else {
            pendingReadURL = articleURL
            return
        }
        guard let normalizedURL = URLUnwrapper.ingestURL(from: articleURL) else { return }
        let urlString = normalizedURL.absoluteString
        // If the Safari extension just handed over the already-unlocked page HTML for
        // this URL, render that instead of re-fetching (which could re-lock).
        let prefetchedHTML = SafariContentStore.take(for: articleURL)
        Task { @MainActor in
            let result = await ReadingListIngestor.shared.handleSavePress(
                urlString: urlString, prefetchedHTML: prefetchedHTML,
                // The Safari extension only captures the article body AFTER unlocking it
                // on-screen, so trust it past the (now-stale) publisher paywall signal.
                trustsPrefetchedHTML: prefetchedHTML != nil)
            let itemID: UUID?
            switch result {
            case .saved(let item), .savedNeedsOwnerInstall(let item, _),
                 .sentToEreaders(let item),
                 .sentToFriends(let item), .friendPromptRequested(let item):
                itemID = item.id
            case .ignored: itemID = ReadingListStore.shared.item(forURLString: urlString)?.id
            case .blockedByInterop:
                // Unpaid cross-surface save — discarded; the ingest gate has
                // already shown the interop prompt. Nothing to open.
                return
            }
            nav.popToRootViewController(animated: false)
            guard let itemID, let item = ReadingListStore.shared.item(withID: itemID)
            else { return }
            if let list = nav.viewControllers.first as? ReadingListViewController {
                list.open(item, presenter: list)
            } else if let cards = nav.viewControllers.first as? ArticleCardsViewController {
                cards.openExternally(item)
            }
        }
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Action Button onboarding: the one-shot "installed the shortcut but never
        // ran it" skip. Unconditional — the state machine self-gates (a no-op
        // unless this surface was left `awaitingShortcutRun`).
        ActionButtonOnboardingStore.shared.handleAppForegrounded(
            forSurface: AppSurfaceConfig.current.storageIdentifier)
        // Items may have been added by the intent while we were backgrounded.
        NotificationCenter.default.post(name: .readingListChanged, object: nil)
        // purgeExpired() does manifest disk I/O (+ file deletion) under a lock;
        // keep it off the main thread (the store already posts its own change
        // notification back on main).
        DispatchQueue.global(qos: .utility).async {
            SavedMediaStore.shared.purgeExpired()
        }
        ReadingListIngestor.shared.ingestAllPending()
        ArticleSendCoordinator.shared.retryPendingSends()
        Task { await IncomingMailImporter.shared.importNewMail() }
        // Resume any link preloading left incomplete (interrupted save / new depth).
        PreloadCoordinator.shared.resumeIncomplete()
        // Resume any downloads a Wi-Fi-only policy deferred, now that we're
        // foregrounding (possibly on Wi-Fi for the first time since they queued).
        if AppSurfaceConfig.current == .downloader {
            Task { await LiveMediaDownloadManager.shared.resumePendingWiFiDownloads() }
        }
        // A notification tapped while the app was backgrounded.
        applyPendingNotificationRoute()
        // A double save with "ask every time" bounced the user into Luna: present
        // the friend selector for the double-saved item.
        applyPendingFriendPrompt()
    }

    /// Presents the friend-selector share sheet for a pending double-save
    /// "ask every time" hand-off (recorded by the Save App Intent right before
    /// the Shortcut opened Luna). One-shot; consumed only once the main UI is
    /// actually up so an onboarding-first launch doesn't swallow it.
    private func applyPendingFriendPrompt() {
        guard let nav = mainNavigationController,
              let root = nav.viewControllers.first
        else { return }
        let surface = AppSurfaceConfig.current.storageIdentifier
        guard let urlString = DoubleSaveActionStore.shared
            .takePendingFriendPrompt(forSurface: surface) else { return }
        let item = ReadingListStore.shared.item(forURLString: urlString)
        nav.dismiss(animated: false)
        nav.popToRootViewController(animated: false)
        SendToFriendSheet.present(
            from: root, item: item, urlString: urlString, title: item?.title)
    }

    private func uiTestRootViewController() -> UIViewController? {
        #if DEBUG
        if UITestSeeder.requestsOnboarding {
            return OnboardingFlow.make { [weak self] in self?.showMainUI() }
        }
        if let screen = UITestSeeder.requestedScreen {
            return UITestScreenBuilder.rootViewController(for: screen)
        }
        if UITestSeeder.isActive {
            return UINavigationController(rootViewController: ReadingListViewController())
        }
        #endif
        return nil
    }

    private func showMainUI() {
        guard let window else { return }
        window.rootViewController = makeMainRootViewController()
        mainNavigationController?.installLunarEclipseTransition()
        window.layoutIfNeeded()
    }
}

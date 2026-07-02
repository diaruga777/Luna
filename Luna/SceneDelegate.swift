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
import LunaSemantic
import LunaStorage
import LunaTransitions
import LunaURLClassification
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    /// Per-app (private defaults) flag: each Luna app shows onboarding once.
    private static let onboardingCompleteKey = "hasCompletedOnboarding"

    var window: UIWindow?

    /// A `lunareader://read` article URL that arrived before the main UI was up.
    private var pendingReadURL: String?
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

    /// Pushes the Pending Requests screen onto the reading-list nav once the main
    /// UI exists.
    private func applyPendingNotificationRoute() {
        guard Self.pendingRequestsRoute,
              let nav = window?.rootViewController as? UINavigationController else { return }
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

        // DEBUG-only UI-test seeding (no-op unless launched with `-uiTestState`).
        UITestSeeder.applyIfNeeded()
        if let rootForUITest = uiTestRootViewController() {
            window.rootViewController = rootForUITest
            self.window = window
            window.makeKeyAndVisible()
            return
        }

        #if DEBUG
        if let effect = ExperimentalSettingsScreen.debugEffectScreen(
            named: debugLaunchArgValue(after: "-openEffect")) {
            window.rootViewController = UINavigationController(rootViewController: effect)
            self.window = window
            window.makeKeyAndVisible()
            return
        }
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
                self?.applyPendingNotificationRoute()
            }
            window.rootViewController = OnboardingFlow.make(onFinished: finish)
        } else {
            window.rootViewController = UINavigationController(
                rootViewController: ReadingListViewController(surface: AppSurfaceConfig.current))
        }
        self.window = window
        window.makeKeyAndVisible()
        installDotMatrixTransitions()

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

    /// Dispatches an incoming URL: a `lunareader://read` link opens the reader.
    private func route(_ url: URL) {
        if let articleURL = LunaDeepLink.articleURL(from: url) {
            openReader(articleURL: articleURL)
        }
    }

    /// Saves the article (if new), then opens it the way tapping its list row does.
    /// Stashes the URL if the main UI isn't up yet (onboarding).
    private func openReader(articleURL: String) {
        guard let nav = window?.rootViewController as? UINavigationController else {
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
                urlString: urlString, prefetchedHTML: prefetchedHTML)
            let itemID: UUID?
            switch result {
            case .saved(let item), .sentToEreaders(let item): itemID = item.id
            case .ignored: itemID = ReadingListStore.shared.item(forURLString: urlString)?.id
            }
            nav.popToRootViewController(animated: false)
            guard let itemID, let item = ReadingListStore.shared.item(withID: itemID),
                  let list = nav.viewControllers.first as? ReadingListViewController
            else { return }
            list.open(item, presenter: list)
        }
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Items may have been added by the intent while we were backgrounded.
        NotificationCenter.default.post(name: .readingListChanged, object: nil)
        ReadingListIngestor.shared.ingestAllPending()
        Task { await IncomingMailImporter.shared.importNewMail() }
        SemanticIndexer.shared.scheduleRun()
        // Resume any link preloading left incomplete (interrupted save / new depth).
        PreloadCoordinator.shared.resumeIncomplete()
        // A notification tapped while the app was backgrounded.
        applyPendingNotificationRoute()
    }

    private func uiTestRootViewController() -> UIViewController? {
        #if DEBUG
        if UITestSeeder.requestedOnboardingStep != nil {
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
        window?.rootViewController = UINavigationController(
            rootViewController: ReadingListViewController(surface: AppSurfaceConfig.current))
        installDotMatrixTransitions()
    }

    /// Prewarm the GPU overlay and route the root navigation controller's push/pop
    /// through the Dot Matrix pixel-wipe (a no-op when off / Metal unavailable).
    private func installDotMatrixTransitions() {
        guard let window else { return }
        DotMatrixTransitionCenter.shared.prewarm(in: window)
        (window.rootViewController as? UINavigationController)?.installDotMatrixTransitions()
    }
}

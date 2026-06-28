//
//  SceneDelegate.swift
//  Clip
//
//  Clip is a weblink reader: save links from Safari (via the bundled Safari
//  extension + action-button shortcut), then read them in a scrolling reader
//  or an RSVP speed reader. Articles can be shared with friends (CloudKit
//  messages) and sent to a Kindle.
//

import ClipReadingList
import ClipArchiveReader
import ClipSemantic
import ClipSocial
import ClipStorage
import ClipURLClassification
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    /// A friend URL that arrived before onboarding finished; replayed once an
    /// identity exists.
    private var pendingFriendURL: URL?
    /// A `clickreader://read` article URL that arrived before the main UI was up.
    private var pendingReadURL: String?
    /// A friend whose settings page a tapped first-share notification asked to
    /// open; applied once the main UI (reading-list nav) exists. Static because
    /// the notification tap is delivered to the AppDelegate, before any scene may
    /// have connected.
    private static var pendingFriendSettingsUUID: UUID?
    /// Set when a tapped friend-added notification asks to open the friends list.
    private static var pendingFriendsList = false

    /// Entry point for a tapped first-share notification (called from
    /// `AppDelegate.userNotificationCenter(_:didReceive:)`). Routes to the
    /// friend's settings page now if the UI is ready, else stashes it for when it
    /// is (scene connect / onboarding finish / foreground).
    static func routeToFriendSettings(friendUUID: UUID) {
        pendingFriendSettingsUUID = friendUUID
        activeSceneDelegate()?.applyPendingNotificationRoute()
    }

    /// Entry point for a tapped friend-added notification — opens the friends list.
    static func routeToFriends() {
        pendingFriendsList = true
        activeSceneDelegate()?.applyPendingNotificationRoute()
    }

    private static func activeSceneDelegate() -> SceneDelegate? {
        UIApplication.shared.connectedScenes.compactMap { $0.delegate as? SceneDelegate }.first
    }

    /// Applies whichever notification-tap route is pending, once the main UI exists.
    private func applyPendingNotificationRoute() {
        applyPendingFriendSettings()
        applyPendingFriendsList()
    }

    /// Pushes the friends list onto the reading-list nav (friend-added tap).
    private func applyPendingFriendsList() {
        guard Self.pendingFriendsList,
              let nav = window?.rootViewController as? UINavigationController else { return }
        Self.pendingFriendsList = false
        nav.dismiss(animated: false)
        nav.popToRootViewController(animated: false)
        nav.pushViewController(FriendsViewController(), animated: true)
    }

    /// Pushes the pending friend's settings page onto the reading-list nav, if the
    /// main UI is up and the friend still exists. No-op (leaving the request
    /// pending) during onboarding.
    private func applyPendingFriendSettings() {
        guard let uuid = Self.pendingFriendSettingsUUID,
              let nav = window?.rootViewController as? UINavigationController,
              let friend = FriendsStore.shared.friend(withUUID: uuid) else { return }
        Self.pendingFriendSettingsUUID = nil
        nav.dismiss(animated: false) // clear any presented reader/sheet
        nav.popToRootViewController(animated: false)
        let detail = FriendDetailViewController(friend: friend) { [weak nav] in
            nav?.popViewController(animated: true)
        }
        nav.pushViewController(detail, animated: true)
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
        // Debug hook: deep-link straight to an experimental effect screen via
        // `-openEffect <name>` (the settings toolbar isn't reachable via UI
        // automation). Gated to DEBUG + an explicit launch arg, so production never
        // hits it.
        if let effect = ExperimentalSettingsScreen.debugEffectScreen(
            named: debugLaunchArgValue(after: "-openEffect")) {
            window.rootViewController = UINavigationController(rootViewController: effect)
            self.window = window
            window.makeKeyAndVisible()
            return
        }
        // Deep-link straight into the interactive archive/bypass reader for a URL, to
        // exercise the trailing-dot WKWebView pre-stage end-to-end.
        if let archiveArg = debugLaunchArgValue(after: "-openArchive"),
           let archiveURL = URL(string: archiveArg) {
            // A real item id is required for extraction to save (and not silently bail).
            let item = ReadingListStore.shared.addIfAbsent(urlString: archiveURL.absoluteString)
                ?? ReadingListStore.shared.add(urlString: archiveURL.absoluteString)
            let reader = ArchiveWebReaderViewController(articleURL: archiveURL, itemID: item.id)
            window.rootViewController = UINavigationController(rootViewController: reader)
            self.window = window
            window.makeKeyAndVisible()
            return
        }
        #endif

        if KeychainIdentityStore.shared.loadIdentity() == nil {
            window.rootViewController = OnboardingFlow.make { [weak self] in
                self?.showMainUI()
                if let url = self?.pendingFriendURL {
                    self?.pendingFriendURL = nil
                    self?.handleFriendURL(url)
                }
                if let articleURL = self?.pendingReadURL {
                    self?.pendingReadURL = nil
                    self?.openReader(articleURL: articleURL)
                }
                self?.applyPendingNotificationRoute()
            }
        } else {
            window.rootViewController = UINavigationController(
                rootViewController: ReadingListViewController())
        }
        self.window = window
        window.makeKeyAndVisible()

        if let url = connectionOptions.urlContexts.first?.url {
            route(url)
        }
        // A notification tapped from a cold launch may have set a pending route
        // before this scene connected.
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

    /// Dispatches an incoming URL: a `clickreader://read` link opens the reader;
    /// anything else is treated as a `clipreader://friend` link.
    private func route(_ url: URL) {
        if let articleURL = ClickDeepLink.articleURL(from: url) {
            openReader(articleURL: articleURL)
        } else {
            handleFriendURL(url)
        }
    }

    /// Saves the article (if new), then opens it the way tapping its list row does
    /// — so a paywalled article opens straight into the in-app archive reader, a
    /// ready article into the native reader, a video into its player. Stashes the
    /// URL if the main UI isn't up yet (onboarding).
    private func openReader(articleURL: String) {
        guard let nav = window?.rootViewController as? UINavigationController else {
            pendingReadURL = articleURL
            return
        }
        guard let normalizedURL = URLUnwrapper.ingestURL(from: articleURL) else { return }
        let urlString = normalizedURL.absoluteString
        Task { @MainActor in
            let result = await ReadingListIngestor.shared.handleSavePress(urlString: urlString)
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
        Task {
            await SocialMessageCenter.shared.drainPendingFriendShares()
            await SocialMessageCenter.shared.processInbox()
        }
        Task { await IncomingMailImporter.shared.importNewMail() }
        SemanticIndexer.shared.scheduleRun()
        // Resume any link preloading left incomplete (interrupted save / new depth).
        PreloadCoordinator.shared.resumeIncomplete()
        // A notification tapped while the app was backgrounded.
        applyPendingNotificationRoute()
    }

    /// The forced root view controller for a UI-test launch, or nil when not in a
    /// UI-test seeded launch. When an onboarding step is requested, shows the full
    /// onboarding flow (the harness walks it); otherwise, when a state is seeded,
    /// shows the main reading list regardless of stored identity. DEBUG-only.
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
            rootViewController: ReadingListViewController())
    }

    /// Parses a `clipreader://friend` URL and runs the confirm-add flow.
    private func handleFriendURL(_ url: URL) {
        guard let card = FriendLink.card(from: url) else { return }
        guard KeychainIdentityStore.shared.loadIdentity() != nil else {
            pendingFriendURL = url
            return
        }
        guard let presenter = window?.rootViewController else { return }
        FriendAddFlow.confirmAndAdd(card: card, from: topViewController(of: presenter))
    }

    private func topViewController(of root: UIViewController) -> UIViewController {
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}

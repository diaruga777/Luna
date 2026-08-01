//
//  SceneDelegate.swift
//  Luna
//
//  Luna is a weblink reader: save links from Safari (via the bundled Safari
//  extension + action-button shortcut), then read them in a scrolling reader
//  or an RSVP speed reader. Articles can be shared with friends by email and
//  sent to a Kindle.
//

import LunaModels
import LunaReadingListUI
import LunaSocialUI
import LunaReadingList
import LunaDesignSystem
import LunaStorage
import LunaURLClassification
import LunaTransitions
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

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

    /// The main navigation controller, whichever shape this app's root takes:
    /// wrapped in the audio mini-player host (article apps' normal main UI) or
    /// bare (the other apps, UI-test and debug roots). The shape is a kind
    /// decision, so `KindWiring` resolves it.
    private var mainNavigationController: UINavigationController? {
        guard let root = window?.rootViewController else { return nil }
        return KindWiring.mainNavigationController(of: root)
    }

    /// Pushes the Pending Requests screen onto the reading-list nav once the main
    /// UI exists. Pending contact requests arrive by email, so only the apps that
    /// do email have this screen to route to.
    private func applyPendingNotificationRoute() {
        guard Self.pendingRequestsRoute, LunaApp.current.sharesByEmail,
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
           let archiveURL = URL(string: archiveArg),
           let archiveRoot = KindWiring.debugArchiveReaderRoot(articleURL: archiveURL) {
            window.rootViewController = archiveRoot
            self.window = window
            window.makeKeyAndVisible()
            return
        }
        #endif

        window.rootViewController = KindWiring.makeRootViewController()
        self.window = window
        window.makeKeyAndVisible()
        mainNavigationController?.installLunarEclipseTransition()
        AppLaunchTransition.install(in: window)

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

    /// Dispatches an incoming URL: a `<luna scheme>://read` link opens the reader.
    private func route(_ url: URL) {
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

    /// Saves the article (if new), then opens it the way tapping its list row does.
    /// A UI-test or debug root has no main navigation controller — nothing to open into.
    private func openReader(articleURL: String) {
        guard let nav = mainNavigationController,
              let normalizedURL = URLUnwrapper.ingestURL(from: articleURL) else { return }
        let urlString = normalizedURL.absoluteString
        // If the Safari extension just handed over the already-unlocked page HTML for
        // this URL, render that instead of re-fetching (which could re-lock). Always
        // CONSUME the capture (so it can't leak onto a later open), but drop it when
        // the URL unwrapped to a different page: the extension captured the wrapper
        // it was sitting on — a publisher's subscribe interstitial holds the article
        // behind `?dest=` — so those bytes are the subscription pitch, not the article.
        let capturedHTML = SafariContentStore.take(for: articleURL)
        let prefetchedHTML = URLUnwrapper.unwrapsToDifferentPage(articleURL)
            ? nil
            : capturedHTML
        Task { @MainActor in
            let result = await ReadingListIngestor.shared.handleSavePress(
                urlString: urlString, prefetchedHTML: prefetchedHTML,
                // The Safari extension only captures the article body AFTER unlocking it
                // on-screen, so trust it past the (now-stale) publisher paywall signal.
                trustsPrefetchedHTML: prefetchedHTML != nil)
            let itemID: UUID?
            switch result {
            case .saved(let item),
                 .sentToEreaders(let item),
                 .sentToFriends(let item), .friendPromptRequested(let item),
                 // In-app opens pass no double-save surface, so this can't
                 // arise here — but the item is the one to open either way.
                 .exportRequested(let item, _):
                itemID = item.id
            case .ignored: itemID = ReadingListStore.shared.item(forURLString: urlString)?.id
            case .unsupportedKind:
                // Foreign-kind save — discarded; the ingest gate has already
                // shown the unsupported-kind error. Nothing to open.
                return
            }
            nav.popToRootViewController(animated: false)
            guard let itemID, let item = ReadingListStore.shared.item(withID: itemID)
            else { return }
            // Both root shapes (list / article cards) conform to
            // `ExternalItemOpening`, so no kind-specific downcast is needed.
            (nav.viewControllers.first as? ExternalItemOpening)?.openExternally(item)
        }
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Items may have been added by the intent while we were backgrounded.
        NotificationCenter.default.post(name: .readingListChanged, object: nil)
        ReadingListIngestor.shared.ingestAllPending()
        if LunaApp.current.sharesByEmail {
            Task { await IncomingMailImporter.shared.importNewMail() }
        }
        // Kind-specific foreground work: saved-media purge + deferred Wi-Fi
        // download resume (media apps), pending-send retry + link-preload
        // resume (article apps).
        KindWiring.sceneDidForeground()
        // A notification tapped while the app was backgrounded.
        applyPendingNotificationRoute()
    }

    private func uiTestRootViewController() -> UIViewController? {
        #if DEBUG
        // The deep-linked screen catalog is kind-woven (readers, price editor,
        // saved-media screen), so only the central Luna app — the UI-test /
        // screenshot host — can build it; the single-kind apps return nil here.
        if let name = UITestSeeder.requestedScreenName,
           let root = KindWiring.uiTestRootViewController(named: name) {
            return root
        }
        // A bare `-uiTestState` seed used to force the sectioned table list as the
        // root. That list had no other caller left, so it was deleted — a seeded
        // launch now falls through to the app's REAL root (its card deck), which is
        // what a screenshot run wants anyway.
        #endif
        return nil
    }
}

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
import LunaSavesUI
import LunaSocialUI
import LunaSaves
import LunaDesignSystem
import LunaStorage
import LunaURLClassification
import LunaTransitions
import LunaWeekly
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    /// The main navigation controller, whichever shape this app's root takes:
    /// wrapped in the audio mini-player host (article apps' normal main UI) or
    /// bare (the other apps, UI-test and debug roots). The shape is a kind
    /// decision, so `KindWiring` resolves it.
    private var mainNavigationController: UINavigationController? {
        guard let root = window?.rootViewController else { return nil }
        return KindWiring.mainNavigationController(of: root)
    }

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        AppearanceSettings.apply(to: window)

        #if DEBUG
        // Staged mode (`claudedocs/staging.md`): seed the stage's fixtures, then
        // either show the screen it builds or — for a deck stage, which wants
        // the app's REAL root against staged data — fall through below.
        if LunaStage.isActive {
            if let stageRoot = LunaStage.rootViewController() {
                window.rootViewController = stageRoot
                self.window = window
                window.makeKeyAndVisible()
                return
            }
        }
        #endif

        // DEBUG-only UI-test seeding (no-op unless launched with `-uiTestState`).
        UITestSeeder.applyIfNeeded()

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
        if url.isFileURL {
            openLunaFile(at: url)
            return
        }
        if let itemID = LunaDeepLink.llmHandoffItemID(from: url) {
            // The extension's hand-off could not open the provider itself.
            mainNavigationController?.popToRootViewController(animated: false)
            KindWiring.openLLMHandoff(itemID: itemID)
            return
        }
        if let itemID = LunaDeepLink.priceTrackerAddSellerItemID(from: url) {
            if let nav = mainNavigationController {
                KindWiring.openPriceTrackerAddSeller(itemID: itemID, navigationController: nav)
            }
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
        if LunaDeepLink.isResolvedMediaLink(url) {
            // Safari's in-page player already resolved the video and wrote the
            // assets to the App Group; this link carries no payload, it just
            // says "drain". An app with no media kind drains nothing — and
            // nothing could have queued anything for it either.
            //
            // This launch exists only to persist the save, start the transfer
            // and request the Live Activity — the user is going straight back to
            // Safari — so hold the splash rather than crossfading to a deck they
            // will never look at.
            AppLaunchTransition.holdForHandoff()
            mainNavigationController?.popToRootViewController(animated: false)
            KindWiring.drainPendingResolvedMedia(
                returningToSource: LunaDeepLink.requestsReturnToSource(url))
            return
        }
        if LunaDeepLink.isPluginModelLink(url) {
            // Safari's plugin walk already ran `ingest` and wrote the Model to
            // the App Group; this link carries no payload, it just says
            // "drain" (`claudedocs/plans/plugin-platform.md` §13.1).
            AppLaunchTransition.holdForHandoff()
            mainNavigationController?.popToRootViewController(animated: false)
            KindWiring.drainPendingPluginModels(
                returningToSource: LunaDeepLink.requestsReturnToSource(url))
            return
        }
        if let caseID = LunaDeepLink.pluginRecoveryCaseID(from: url) {
            // Safari persisted the bounded case in the shared App Group; the
            // route carries only its id so nested page URLs cannot be damaged
            // by URL-query encoding. Only central Luna installs the workshop.
            mainNavigationController?.popToRootViewController(animated: false)
            KindWiring.openPendingPluginRecoveryWorkshop(caseID: caseID)
            return
        }
        if let scheme = url.scheme, LunaDeepLink.allSchemes.contains(scheme),
           url.host == "settings", url.path == "/photos" {
            if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(settingsURL)
            }
            return
        }
        if url.host == "media" {
            openMediaDeepLink(url)
            return
        }
        if let saveURL = LunaDeepLink.saveURL(from: url) {
            // Safari's "Finish in Luna". The save runs here, in the foreground,
            // so a plugin that needs a browser step gets one straight away
            // instead of parking a lock the user then has to tap.
            openReader(articleURL: saveURL)
            return
        }
        if let articleURL = LunaDeepLink.articleURL(from: url) {
            // Only Downloader media pill taps carry `&ret=safari`: their Live
            // Activity continues to show the download after the app returns to
            // Safari. Reader and Price Tracker cards are their destinations.
            openReader(articleURL: articleURL, returnsToSource: LunaDeepLink.requestsReturnToSource(url))
        }
    }

    /// Open In, Files, or a provider's "Open in Luna": a Luna file
    /// (`claudedocs/luna-file.md`). The inbox copy is deleted as soon as it is
    /// read — `LSSupportsOpeningDocumentsInPlace` is false, so nothing else
    /// will ever look at it — and the surface's own intake witness decides what
    /// the user sees. A file that is not a Luna file at all says so in one
    /// line; Luna claims only its own document types, so this is rare.
    private func openLunaFile(at url: URL) {
        let text: String
        switch LunaFileReader.readText(at: url) {
        case .success(let value):
            text = value
        case .failure(let error):
            _ = LunaFileReader.deleteInboxCopy(at: url)
            presentLunaFileAlert(error.message)
            return
        }
        _ = LunaFileReader.deleteInboxCopy(at: url)

        switch LunaFileIntake.classify(text: text) {
        case .success(.recovery(let file)):
            LunaFileIntake.handler?.handleRecovery(file, sourceURL: url)
        case let .success(.plugin(headerJSON, source)):
            LunaFileIntake.handler?.handlePlugin(source: source, headerJSON: headerJSON)
        case .failure(let error):
            presentLunaFileAlert(error.message)
        case .none:
            presentLunaFileAlert(L10n.string("LunaFile_notALunaFileMessage"))
        }
    }

    private func presentLunaFileAlert(_ message: String) {
        guard let root = window?.rootViewController else { return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Common_ok"), style: .default))
        (root.presentedViewController ?? root).present(alert, animated: true)
    }

    /// The download Live Activity's tap-to-view link: centers the deck on the
    /// saved item (a local file) or opens it in Photos (a Photos-backed save),
    /// without a save. Still-downloading or an unknown URL simply lands on the
    /// deck — today's behavior for any other cold/foreground launch.
    ///
    /// The finished card's Share button is the same route plus `&share=1`: it
    /// centers the card AND raises the system share sheet over the downloaded
    /// file. Every case that has no file to share (a Photos-backed save, still
    /// downloading, an unknown URL, an app that links no media kind) reaches
    /// exactly the behavior above instead.
    private func openMediaDeepLink(_ url: URL) {
        guard let urlString = LunaDeepLink.mediaViewURLString(from: url), let nav = mainNavigationController
        else { return }
        nav.popToRootViewController(animated: false)
        guard case let .center(itemID) = KindWiring.mediaDeepLinkAction(forURLString: urlString)
        else { return }
        if LunaDeepLink.mediaShareRequested(from: url),
           let item = SavesStore.shared.item(withID: itemID),
           let exporter = KindWiring.mediaShareFileExporter {
            shareDownloadedMedia(item, using: exporter, in: nav)
        } else {
            (nav.viewControllers.first as? CardCarouselHostViewController)?.centerCard(onItemID: itemID)
        }
    }

    /// Centers the deck on the downloaded item, then hands a materialized copy
    /// of its file to `UIActivityViewController`. Producing that copy is the
    /// media kind's job (`MediaShareFileExporting`) and can fail — a file that
    /// moved to Photos or vanished — in which case this degrades to the plain
    /// open the link would otherwise have done.
    private func shareDownloadedMedia(
        _ item: SavedItem, using exporter: any MediaShareFileExporting,
        in nav: UINavigationController
    ) {
        let deck = nav.viewControllers.first
        (deck as? CardCarouselHostViewController)?.centerCard(onItemID: item.id)
        Task { @MainActor in
            guard let fileURL = await exporter.exportedFileURL(forItemID: item.id) else {
                (deck as? CardCarouselHostViewController)?.openExternally(item)
                return
            }
            let activity = UIActivityViewController(
                activityItems: [fileURL], applicationActivities: nil)
            activity.completionWithItemsHandler = { _, _, _, _ in
                exporter.discardExportedFile(at: fileURL)
            }
            // On iPad this presents as a popover, which needs an anchor; the
            // centered card is the only thing this launch pointed at.
            let anchor = deck?.view ?? nav.view
            activity.popoverPresentationController?.sourceView = anchor
            activity.popoverPresentationController?.sourceRect = CGRect(
                x: (anchor?.bounds.midX ?? 0), y: (anchor?.bounds.midY ?? 0),
                width: 0, height: 0)
            (nav.presentedViewController ?? nav).present(activity, animated: true)
        }
    }

    /// Saves the article (if new), then opens it the way tapping its list row does.
    /// A UI-test or debug root has no main navigation controller — nothing to open into.
    /// `returnsToSource`: a Downloader media pill save bounces back to the
    /// original https page in Safari once its download has started and its Live
    /// Activity can report progress — see `SafariReturnPolicy` and
    /// `claudedocs/safari-extension.md`.
    private func openReader(articleURL: String, returnsToSource: Bool = false) {
        guard let nav = mainNavigationController,
              let normalizedURL = URLUnwrapper.ingestURL(from: articleURL) else { return }
        let urlString = normalizedURL.absoluteString
        // If the Safari extension just handed over the already-unlocked page HTML for
        // this URL, render that instead of re-fetching (which could re-lock). Always
        // CONSUME the capture (so it can't leak onto a later open), but drop it when
        // the URL unwrapped to a different page: the extension captured the wrapper
        // it was sitting on — a publisher's subscribe interstitial holds the article
        // behind `?dest=` — so those bytes are the subscription pitch, not the article.
        //
        // The extension only captures the article body AFTER unlocking it on-screen,
        // so the capture is trusted past the (now-stale) publisher paywall signal —
        // this is the one place in the codebase that calls `safariHandoff`.
        let capturedHTML = SafariContentStore.take(for: articleURL)
        let page: CapturedPage = URLUnwrapper.unwrapsToDifferentPage(articleURL)
            ? .none
            : capturedHTML.map { .safariHandoff(html: $0) } ?? .none
        Task { @MainActor in
            let result = await SavesIngestor.shared.handleSavePress(
                urlString: urlString, page: page)
            let itemID: UUID?
            var outcome: SafariReturnPolicy.Outcome = .handled
            switch result {
            case .saved(let item),
                 .sentToEreaders(let item),
                 .sentToFriends(let item), .friendPromptRequested(let item),
                 // In-app opens pass no double-save surface, so this can't
                 // arise here — but the item is the one to open either way.
                 .exportRequested(let item, _):
                itemID = item.id
            case .ignored: itemID = SavesStore.shared.item(forURLString: urlString)?.id
            case .unsupportedKind:
                // Foreign-kind save — discarded; the ingest gate has already
                // shown the unsupported-kind error. Nothing to open, and never
                // a bounce (the error surface needs to be seen in-app).
                return
            }
            nav.popToRootViewController(animated: false)
            guard let itemID, let item = SavesStore.shared.item(withID: itemID)
            else { return }
            if item.state == .failed { outcome = .failedOrUnsupported }
            let kind: SafariReturnPolicy.Kind = item.isPriceTracker
                ? .product
                : (SavesSectioning.rendersAsReader(item) ? .article : .media)
            if SafariReturnPolicy.shouldReturn(outcome: outcome, kind: kind, flagged: returnsToSource),
               let originalURL = URL(string: articleURL) {
                // The page the user was ON — never `URLUnwrapper`'s resolved
                // result — and skip the deck-centering leg below: the user
                // won't see it, and a deck reload right as the app backgrounds
                // is an animation with no audience.
                await UIApplication.shared.open(originalURL)
                return
            }
            // A Safari (or other app-scheme) handoff lands on the saved card.
            // It must never open the source URL in an in-app browser; that
            // would re-show the page the user just saved instead of Luna's
            // reader/product/media card. The one deep-link exception is the
            // explicit price-add-seller route handled at the start of `route`.
            (nav.viewControllers.first as? CardCarouselHostViewController)?.centerCard(onItemID: item.id)
        }
    }

    /// The hand-off worked: the app is on its way back to Safari, so the held
    /// splash can retire off-screen and the next visit is an ordinary launch.
    /// (A hand-off that never manages to leave releases on its own timeout instead —
    /// `AppLaunchTransition.maximumHandoffHold`. This is deliberately NOT
    /// `sceneWillEnterForeground`, which a cold launch runs moments after the
    /// hold is taken.)
    func sceneDidEnterBackground(_ scene: UIScene) {
        AppLaunchTransition.releaseHandoffHold()
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // A staged run is a frozen world; foregrounding must not re-fetch,
        // re-import or re-purge anything into it.
        guard !LunaStage.isActive else { return }
        // An intent may have added items while the app was backgrounded.
        NotificationCenter.default.post(name: .savesChanged, object: nil)
        SavesIngestor.shared.ingestAllPending()
        if LunaApp.current.sharesByEmail {
            Task { await IncomingMailImporter.shared.importNewMail() }
        }
        // Kind-specific foreground work: saved-media purge + deferred Wi-Fi
        // download resume (media apps), pending-send retry + link-preload
        // resume (article apps).
        KindWiring.sceneDidForeground()
        // The weekly pick may have changed while the app was backgrounded
        // (debounced to at most one pull a minute inside the refresher).
        Task { @MainActor in
            await WeeklySaveRefresher.shared.refreshWeeklySaves()
            await WeeklySaveRefresher.shared.checkProposalsIfKeyHolder()
        }
    }
}

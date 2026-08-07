//
//  KindWiring+Luna.swift
//  Luna
//
//  Per-app composition root: registers exactly the per-kind processors,
//  ingestor handlers, and UI/lifecycle seams this app's target links. EXACTLY
//  ONE KindWiring variant is compiled into each app target (the other variants
//  are excluded via the synchronized group's per-target membership exceptions)
//  — the registries and the static lifecycle API below mirror the link set.
//

import LunaArchiveReader
import LunaArticleIngest
import LunaAudioPlayback
import LunaHTMLClassification
import LunaIngest
import LunaMailAccount
import LunaMailTransport
import LunaMediaDownload
import LunaModels
import LunaPlatforms
import LunaPriceIngest
import LunaPriceUI
import LunaReaderUI
import LunaReadingList
import LunaSend
import LunaSocialUI
import LunaStorage
import UIKit

enum KindWiring {
    /// The central app's deck draws every kind, so a save into EITHER store —
    /// article, media, tracker — is the real content onboarding completes around.
    static let onboardingContentWatch = OnboardingContentWatch(
        changeNotifications: [.readingListChanged, .savedMediaChanged],
        storedIdentifiers: {
            Set(ReadingListStore.shared.items().map(\.id))
                .union(SavedMediaStore.shared.items().map(\.id))
        })

    /// Migration only — onboarding stores nothing (see `OnboardingLegacyDemoSave`).
    static let legacyOnboardingDemoSave = OnboardingLegacyDemoSave(
        cleanup: { BundledLunaArticle.cleanupLegacyTemporarySave() })

    @MainActor
    static func install() {
        #if DEBUG
        AppOnboardingStore.shared.resetIfRequested()
        // Staged mode's catalogs, on the same rule as the kind packs: a kind's
        // stages live with that kind, and this app installs the ones for the
        // kinds it links (`claudedocs/staging.md`). No-op unless launched with
        // `-LunaStage`.
        SharedStageCatalog.install()
        ArticleStageCatalog.install()
        EmailStageCatalog.install()
        MediaStageCatalog.install()
        ProductStageCatalog.install()
        #endif

        // One install per kind this app handles. WHAT each kind registers is
        // defined once in that kind's own module and shared by every surface
        // (app, share ext, action ext, clip) — see `ArticleKindComposition`.
        ArticleKindComposition.install()
        MediaKindComposition.install()
        ProductKindComposition.install()
        // …and the CARD half of each kind, on the same principle: one
        // definition per kind, installed by every app that shows it, so the
        // central deck and each single-kind deck cannot disagree about the
        // same save (`CardKindPresenter.swift`).
        CardKindPresenters.article = ArticleCardPresenter()
        CardKindPresenters.media = MediaCardPresenter()
        CardKindPresenters.product = ProductCardPresenter()
        // The central Luna app handles every kind, so it installs every
        // ingestor handler and every kind-specific presentation hook.
        IngestorKindHandlers.article = ArticleKindHandler()
        IngestorKindHandlers.media = MediaKindHandler()
        IngestorKindHandlers.product = ProductKindHandler()
        PasteboardSuggester.platformPreviewArt = { platform, itemID, urlString in
            await PlatformItemIngestor.shared.pasteboardPreviewArtData(
                platform: platform, itemID: itemID, urlString: urlString)
                .flatMap { UIImage(data: $0) }
        }
        EmailShareCenter.priceGraphSnapshot = { PriceGraphEmailSnapshot.jpegData(for: $0) }

        // Sending needs a connected email account: an attempted send without one
        // redirects to the screen that connects it (its Sharing Account section is
        // the sign-in form until then). Only the email-sending apps install this.
        SendToFriendSheet.accountSetupLauncher = { presenter in
            EmailAndKindleSettingsScreen.pushForAccountSetup(from: presenter)
        }
        // The util card's email nudge goes to the same one place.
        UtilCardContentViewController.emailSetupLauncher = { presenter in
            EmailAndKindleSettingsScreen.pushForAccountSetup(from: presenter)
        }
        installArticleLaunchWiring()
        installMediaLaunchWiring()
        installProductLaunchWiring()
    }

    /// Article-kind launch wiring (identical in the Reader variant).
    private static func installArticleLaunchWiring() {
        // A completion written before a force-quit never received the normal
        // background callback. Promote it before constructing the Reader UI.
        ReadingListStore.shared.archivePendingFinishedItems()

        // Send-to-Kindle emails go out through the connected email account.
        // LunaSend sits below LunaMailTransport, so the transport factory is
        // injected here (extensions leave it nil → Kindle sends are no-ops there).
        ArticleEmailTransportProvider.make = { MailTransportFactory.make() }

        // New audio-playback stack (claudedocs/audio-playback-plan.md, Phase 2):
        // install the autoplay queue provider and register the Now Playing /
        // remote-command coordinator. Registration must happen at launch (not
        // lazily) so a cold background relaunch from a lock-screen play command
        // can restore the persisted session. Read-aloud (the app-wide center,
        // its background session, the window mini-player) belongs exclusively
        // to article-handling apps — the Downloader / Price Tracker variants
        // leave `ReaderAudioLauncher.center` nil, keeping the shared readers on
        // their legacy self-contained `SpeechController` path.
        AudioPlaybackWiring.install()
        // Phase 4 (trimming): opportunistic script-cache builder, wired
        // right after playback so its scriptProvider/scriptPrefetchHandler
        // seams are set before anything could call into the center.
        AudioScriptPipelineWiring.install()

        // The Read Article intent plays through the same center.
        ReadArticleIntent.playArticle = { item, content in
            AudioPlaybackCenter.shared.play(item: item, content: content)
        }

        // The Action Button double save (claudedocs/double-save.md): its
        // "View immediately" returns an article document, and Kindle needs
        // the account/Kindle setup screens. Both are article-only, so both are
        // installed here — matching `ActionButtonIntentSupport.doubleSaveSurface`,
        // which arms double save in exactly the apps that link LunaSend.
        ActionButtonIntentSupport.articleExporter = { item, format in
            try? await ArticleExportService().writePreparingImagesWhenAvailable(
                format, for: item)
        }
        // Exports fetch the article images that haven't landed yet rather than
        // shipping a file with none. The downloader is LunaReaderUI's and the
        // exporters are LunaSend's, so the composition root joins them.
        ArticleExportImages.preparer = { content, item in
            guard let referer = ArticleImageReferer.url(for: item, content: content) else {
                return content
            }
            return await ArticleImageDownloader.download(
                content, itemID: item.id, store: .shared, refererURL: referer)
        }
        DoubleSaveSettingsSupport.kindleSetupLauncher = { presenter in
            guard EmailAccountStore.shared.isConfigured else {
                EmailAndKindleSettingsScreen.pushForAccountSetup(from: presenter)
                return
            }
            presenter.navigationController?.pushViewController(
                KindleSettingsScreen(), animated: true)
        }

        // A bulk import's pass over the saves that came back hard-paywalled:
        // the same web unlock a tap would run, off-screen and giving up on any
        // CAPTCHA (`claudedocs/import-export.md`). Article apps only — there is
        // no article save to unlock anywhere else.
        LinkImportRunner.articleUnlocker = { itemID, urlString in
            await UnattendedArticleUnlock.unlock(itemID: itemID, urlString: urlString)
        }

        // Voice status and installation now live on the Audio settings page.
        VoiceFirstRunPrompt.openVoiceSettings = { presenter in
            let audio = AudioSettingsScreen()
            if let nav = presenter.navigationController {
                nav.pushViewController(audio, animated: true)
            } else {
                let nav = UINavigationController(rootViewController: audio)
                presenter.present(nav, animated: true)
            }
        }
    }

    /// Media-kind launch wiring (identical in the Downloader variant).
    @MainActor
    private static func installMediaLaunchWiring() {
        // Action Button intents hand recognized posts to the media downloader.
        MediaIntentHandoff.install()
        // The util card's inline "Store downloads …" line. Only an app that
        // downloads has anywhere to store, so only an app that links this module
        // installs the choice (`claudedocs/util-card.md`).
        MediaUtilCardStorageChoice.install()
        // URL Rescue's media leg: download engine-resolved assets directly.
        URLRescueWiring.mediaResolverFactory = { SocialMediaResolver() }
        URLRescueWiring.mediaRescueStarter = { sourceURLString, title, assets in
            await LiveMediaDownloadManager.shared.startWithResolvedAssets(
                sourceURLString: sourceURLString, title: title, assets: assets)
        }
        // The factory reset's media leg: a Live Activity outlives the process
        // that started it, so the wipe has to end them itself.
        FactoryReset.additionalErasers.append {
            await LiveMediaDownloadManager.shared.endAllActivities()
        }
        LinkImportRunner.mediaDownloadProgress = MediaImportProgress.observe
        // A bulk import runs its own progress bar; the per-transfer Live
        // Activity alerts (banner + sound + haptic) would buzz twice per link
        // over the top of it.
        // Photos access asked for at the START of an import, not when the first
        // transfer wants it (`claudedocs/import-export.md`).
        LinkImportRunner.mediaStoragePreflight = { urlStrings in
            await MediaPhotosPreflight.requestAccessIfNeeded(for: urlStrings)
        }
        LinkImportRunner.mediaAlertSuspension = { suspended in
            if suspended {
                LiveMediaDownloadManager.suspendActivityAlerts()
            } else {
                LiveMediaDownloadManager.resumeActivityAlerts()
            }
        }
    }

    /// Product-kind launch wiring (identical in the Price Tracker variant).
    private static func installProductLaunchWiring() {
        // Install the in-app "Read instead" behavior for the price-tracking editor
        // (shared with the extensions, which can't reference the ingestor): a
        // forced-article re-save, no re-detection back into a tracker.
        PriceTrackingViewController.defaultSaveAsArticle = { urlString in
            Task { await ReadingListIngestor.shared.saveAsArticle(urlString: urlString) }
        }
        // Price Tracker "no price" → "Ask Apple Intelligence" resolver (URL
        // Rescue Phase 6 UI).
        PriceTrackingViewController.intelligentPriceResolver = { urlString in
            guard let info = await URLRescueWiring.rescueProductInfo(urlString: urlString)
            else { return nil }
            return PriceTrackingViewController.ResolvedPrice(
                amount: info.priceAmount, currency: info.priceCurrency)
        }
    }

    // MARK: - Root UI shape

    /// The all-kinds card deck, wrapped in the window-level audio mini-player
    /// host (read-aloud is an article-app feature; the bar floats above the
    /// bottom safe area, survives every push/pop, and hides while idle).
    static func makeRootViewController() -> UIViewController {
        let content: UIViewController = ArticleCardsViewController()
        let nav = UINavigationController(rootViewController: content)
        return MiniPlayerHostViewController(content: nav)
    }

    private static func makeCompletedRootViewController() -> UIViewController {
        let nav = UINavigationController(rootViewController: ArticleCardsViewController())
        return MiniPlayerHostViewController(content: nav)
    }

    static func makeSetupReplayRootViewController() -> UIViewController {
        makeCompletedRootViewController()
    }

    static func mainNavigationController(of root: UIViewController) -> UINavigationController? {
        if let host = root as? MiniPlayerHostViewController {
            return host.contentNavigationController
        }
        return root as? UINavigationController
    }

    static func settingsCategories() -> [SettingsCategory] {
        [
            SettingsCategory(title: L10n.string("Common_reader"), symbol: "textformat.size") { ReaderSettingsScreen() },
            SettingsCategory(title: L10n.string("Common_audio"), symbol: "headphones") { AudioSettingsScreen() },
            SettingsCategory(
                title: L10n.string("Common_email"),
                symbol: "envelope",
                detail: {
                    EmailAccountStore.shared.authenticationIssue == nil
                        ? nil : L10n.string("Common_signInRequired")
                }
            ) { EmailAndKindleSettingsScreen() },
            SettingsCategory(
                title: L10n.string("Common_kindle"), symbol: "book.closed",
                requiresEmail: true,
                makePrerequisite: {
                    let email = EmailAndKindleSettingsScreen()
                    email.focusesAddressField = true
                    return email
                }
            ) {
                KindleSettingsScreen()
            },
            SettingsCategory(title: L10n.string("Common_downloads"), symbol: "arrow.down.circle") {
                DownloadsSettingsScreen()
            },
        ]
    }

    // MARK: - Lifecycle (called by AppDelegate/SceneDelegate at fixed points)

    static func appDidLaunch() {
        legacyOnboardingDemoSave.cleanup()
        // The all-kinds deck draws real media cards, so it needs the same
        // cross-process bridge the Downloader has: a save or delete made by an
        // extension is a different process, and only a Darwin notification
        // brings its `.savedMediaChanged` post back here.
        SavedMediaStore.startObservingCrossProcessChanges()
        // Sweep any downloaded-but-never-saved media preview files orphaned by a
        // previous run that was killed before its preview screen could clean up.
        // Also apply the saved-media retention policy. Safe at launch (no
        // preview is open yet); off the main thread to not block startup.
        DispatchQueue.global(qos: .utility).async {
            MediaDownloadStorage.purgeAll()
            SavedMediaStore.shared.purgeExpired()
        }
        ArticleSendCoordinator.shared.retryPendingSends()
        LiveMediaDownloadManager.shared.resumeLiveActivities()
    }

    static func appDidEnterBackground() {
        ArticleSendCoordinator.shared.retryPendingSends()
        LiveMediaDownloadManager.shared.resumeLiveActivities()
        // Keeps the Safari extension's history-pill data current even between
        // refresh cycles (e.g. after the user edits an alert threshold or
        // archives a tracker, neither of which triggers a refresh).
        PriceHistoryIndexWriter.regenerate()
    }

    static func sceneDidForeground() {
        // purgeExpired() does manifest disk I/O (+ file deletion) under a lock;
        // keep it off the main thread (the store already posts its own change
        // notification back on main).
        DispatchQueue.global(qos: .utility).async {
            SavedMediaStore.shared.purgeExpired()
        }
        ArticleSendCoordinator.shared.retryPendingSends()
        // Resume any link preloading left incomplete (interrupted save / new depth).
        PreloadCoordinator.shared.resumeIncomplete()
    }

    static func readingListDidChange() {
        // purgeExpired() off the main thread — see sceneDidForeground.
        DispatchQueue.global(qos: .utility).async {
            SavedMediaStore.shared.purgeExpired()
        }
    }

    static func wifiBecameAvailable() {
        Task { await LiveMediaDownloadManager.shared.resumePendingWiFiDownloads() }
        PreloadCoordinator.shared.resumeIncomplete()
    }

    static func retryPendingArticleSends() {
        ArticleSendCoordinator.shared.retryPendingSends()
    }

    /// Overnight mail-fetch backstop for unfinished media jobs — Downloader
    /// only (matches the pre-split gate), so the central app is a no-op.
    static func resumeUnfinishedMediaDownloads() async {}

    static func attachBackgroundURLSessionHandler(_ completionHandler: @escaping () -> Void) {
        LiveMediaDownloadManager.shared.attachBackgroundCompletionHandler(completionHandler)
    }

    /// The download Live Activity's tap-to-view link, resolved against the
    /// saved-media store: a downloaded local file centers/opens the deck's
    /// card; a Photos-backed save opens Photos directly (reusing the card's
    /// own rosette mechanism); still-downloading or unknown lands on the deck.
    static func mediaDeepLinkAction(forURLString urlString: String) -> MediaDeepLinkAction {
        guard let matched = SavedMediaStore.shared.matchingItem(forURLString: urlString) else { return .none }
        switch matched.storageState {
        case .localFile:
            return .centerAndOpen(matched.id)
        case .photosReference(let localIdentifier, _, _):
            MediaCardFactory.openInPhotos(localIdentifier: localIdentifier)
            return .openedExternally
        case .undownloaded:
            return .none
        }
    }

    /// Runs one price-refresh pass and returns the processed-tracker count.
    /// Non-nil only in product-handling apps; its presence is what arms the
    /// price-refresh BGTask registration/scheduling in AppDelegate.
    static let priceRefreshRunner: (() async -> Int)? = {
        await PriceRefreshCoordinator.shared.refreshAndNotify().count
    }

    #if DEBUG
    /// `-openArchive <url>` debug root: the interactive archive reader.
    static func debugArchiveReaderRoot(articleURL: URL) -> UIViewController? {
        let item = ReadingListStore.shared.addIfAbsent(urlString: articleURL.absoluteString)
            ?? ReadingListStore.shared.add(urlString: articleURL.absoluteString)
        let reader = ArchiveWebReaderViewController(articleURL: articleURL, itemID: item.id)
        return UINavigationController(rootViewController: reader)
    }

    /// The deep-linked UI-test screen catalog is kind-woven, so only the
    /// central Luna app (the UI-test/screenshot host) builds it.
    static func uiTestRootViewController(named name: String) -> UIViewController? {
        guard let screen = UITestScreen(rawValue: name) else { return nil }
        return UITestScreenBuilder.rootViewController(for: screen)
    }
    #endif
}

/// Bridges `IngestorArticleHandling` to the article-kind modules: persistence
/// in LunaReaderUI (`ArticleIngestHandler`, `PreloadCoordinator`) and sends in
/// LunaSend (`ArticleSendCoordinator`) — the composition root is the one place
/// allowed to see both tiers at once.
private struct ArticleKindHandler: IngestorArticleHandling {
    private let handler = ArticleIngestHandler(articleBecameReady: {
        ArticleSendCoordinator.shared.articleBecameReady($0)
    })

    func persistArticle(
        _ content: ArticleContent, html: String, for item: ReadingListItem,
        url: URL, store: ReadingListStore
    ) async {
        await handler.persistArticle(content, html: html, for: item, url: url, store: store)
    }

    func ingestDocument(_ item: ReadingListItem, store: ReadingListStore) async {
        await handler.ingestDocument(item, store: store)
    }

    func backfillMissingWebArchives(store: ReadingListStore) {
        handler.backfillMissingWebArchives(store: store)
    }

    func backfillMissingThumbnails(store: ReadingListStore) {
        handler.backfillMissingThumbnails(store: store)
    }

    func articleBecameReady(_ item: ReadingListItem) {
        ArticleSendCoordinator.shared.articleBecameReady(item)
    }

    func preloadPasteboard(content: ArticleContent, sourceURL: URL) {
        PreloadCoordinator.shared.preloadPasteboard(content: content, sourceURL: sourceURL)
    }

    func doubleSaveDestinationIDs() -> [String] {
        ArticleSendCoordinator.shared.doubleSaveDestinationIDs()
    }

    func sendToDestination(_ item: ReadingListItem, destinationID: String) async {
        await ArticleSendCoordinator.shared.send(item, toDestinationID: destinationID)
    }

    func isDestinationConfigured(_ destinationID: String) -> Bool {
        ArticleSendCoordinator.shared.isConfigured(destinationID: destinationID)
    }
}

/// Bridges `IngestorMediaHandling` to LunaPlatforms' `PlatformItemIngestor`.
private struct MediaKindHandler: IngestorMediaHandling {
    func ingestPlatformItem(
        _ item: ReadingListItem, platform: ContentPlatform, platformItemID: String?,
        store: ReadingListStore
    ) async {
        await PlatformItemIngestor.shared.ingest(
            item, platform: platform, platformItemID: platformItemID, store: store)
    }
}

/// Bridges `IngestorProductHandling` to LunaPriceUI's `ProductTrackerIngestor`.
private struct ProductKindHandler: IngestorProductHandling {
    func ingestProductTracker(
        _ item: ReadingListItem, url: URL, product: ProductInfo, store: ReadingListStore
    ) async {
        await ProductTrackerIngestor.shared.ingest(item, url: url, product: product, store: store)
    }
}

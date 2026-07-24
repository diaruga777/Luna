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
import LunaMailTransport
import LunaMediaDownload
import LunaModels
import LunaPlatforms
import LunaPriceIngest
import LunaPriceUI
import LunaReaderUI
import LunaReadingList
import LunaSend
import LunaStorage
import UIKit

enum KindWiring {
    static func install() {
        IngestKindProcessors.article = ArticleIngestProcessor()
        IngestKindProcessors.product = ProductIngestProcessor()
        // The central Luna app handles every kind, so it installs every
        // ingestor handler and every kind-specific presentation hook.
        IngestorKindHandlers.article = ArticleKindHandler()
        IngestorKindHandlers.media = MediaKindHandler()
        IngestorKindHandlers.product = ProductKindHandler()
        ListKindSupport.article = ArticleListSupport()
        ListKindSupport.media = MediaListSupport()
        ListKindSupport.product = ProductListSupport()
        PasteboardSuggester.platformPreviewArt = { platform, itemID, urlString in
            await PlatformItemIngestor.shared.pasteboardPreviewArtData(
                platform: platform, itemID: itemID, urlString: urlString)
                .flatMap { UIImage(data: $0) }
        }
        EmailShareCenter.priceGraphSnapshot = { PriceGraphEmailSnapshot.jpegData(for: $0) }
        // The central Luna app is the only surface whose card deck contains
        // non-article cards; give them their tap routing.
        NonArticleCardOpening.install()

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

        // Wire the read-aloud first-run prompt's "Open Settings" to push the
        // Voice settings screen. Setting this hook is what enables the prompt in
        // the main app (extensions leave it nil → the prompt is skipped).
        VoiceFirstRunPrompt.openVoiceSettings = { presenter in
            let voice = VoiceSettingsScreen()
            if let nav = presenter.navigationController {
                nav.pushViewController(voice, animated: true)
            } else {
                let nav = UINavigationController(rootViewController: voice)
                presenter.present(nav, animated: true)
            }
        }
    }

    /// Media-kind launch wiring (identical in the Downloader variant).
    private static func installMediaLaunchWiring() {
        // Action Button intents hand recognized posts to the media downloader.
        MediaIntentHandoff.install()
        // URL Rescue's media leg: download engine-resolved assets directly.
        URLRescueWiring.mediaResolverFactory = { SocialMediaResolver() }
        URLRescueWiring.mediaRescueStarter = { sourceURLString, title, assets in
            await LiveMediaDownloadManager.shared.startWithResolvedAssets(
                sourceURLString: sourceURLString, title: title, assets: assets)
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
        let nav = UINavigationController(rootViewController: ArticleCardsViewController())
        return MiniPlayerHostViewController(content: nav)
    }

    static func mainNavigationController(of root: UIViewController) -> UINavigationController? {
        if let host = root as? MiniPlayerHostViewController {
            return host.contentNavigationController
        }
        return root as? UINavigationController
    }

    static func settingsCategories() -> [SettingsCategory] {
        [
            SettingsCategory(title: "Reader", symbol: "textformat.size") { ReaderSettingsScreen() },
            // Audio (read-aloud playback) subsumes the old top-level Voice row —
            // the Voice screen is reached from inside it.
            SettingsCategory(title: "Audio", symbol: "headphones") { AudioSettingsScreen() },
            SettingsCategory(title: "Reading List", symbol: "list.bullet") { ReadingListSettingsScreen() },
            SettingsCategory(title: "Email & Sending", symbol: "envelope") { EmailAndKindleSettingsScreen() },
            SettingsCategory(title: "Auto-Download Media", symbol: "photo.badge.arrow.down") {
                DownloadsSettingsScreen()
            },
        ]
    }

    // MARK: - Lifecycle (called by AppDelegate/SceneDelegate at fixed points)

    static func appDidLaunch() {
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

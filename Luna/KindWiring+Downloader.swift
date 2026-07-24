//
//  KindWiring+Downloader.swift
//  Luna
//
//  Per-app composition root: registers exactly the per-kind processors,
//  ingestor handlers, and UI/lifecycle seams this app's target links. EXACTLY
//  ONE KindWiring variant is compiled into each app target (the other variants
//  are excluded via the synchronized group's per-target membership exceptions)
//  — the registries and the static lifecycle API below mirror the link set.
//

import LunaMediaDownload
import LunaModels
import LunaPlatforms
import LunaReadingList
import LunaStorage
import UIKit

enum KindWiring {
    static func install() {
        // Media needs no web-processing pipeline stage (platform recognition
        // is URL-only classification), but its post-save ingestion — metadata,
        // thumbnail, auto-download handoff — is the media ingestor handler.
        IngestorKindHandlers.media = MediaKindHandler()
        ListKindSupport.media = MediaListSupport()
        PasteboardSuggester.platformPreviewArt = { platform, itemID, urlString in
            await PlatformItemIngestor.shared.pasteboardPreviewArtData(
                platform: platform, itemID: itemID, urlString: urlString)
                .flatMap { UIImage(data: $0) }
        }
        // Action Button intents hand recognized posts to the media downloader.
        MediaIntentHandoff.install()
        // URL Rescue's media leg: download engine-resolved assets directly.
        URLRescueWiring.mediaResolverFactory = { SocialMediaResolver() }
        URLRescueWiring.mediaRescueStarter = { sourceURLString, title, assets in
            await LiveMediaDownloadManager.shared.startWithResolvedAssets(
                sourceURLString: sourceURLString, title: title, assets: assets)
        }
    }

    // MARK: - Root UI shape

    /// The saved-media card deck in a bare nav controller — no audio
    /// mini-player host (read-aloud is an article-app feature).
    static func makeRootViewController() -> UIViewController {
        UINavigationController(rootViewController: SavedMediaCardsViewController())
    }

    static func mainNavigationController(of root: UIViewController) -> UINavigationController? {
        root as? UINavigationController
    }

    static func settingsCategories() -> [SettingsCategory] {
        [
            SettingsCategory(title: "Downloads", symbol: "arrow.down.circle") {
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
        LiveMediaDownloadManager.shared.resumeLiveActivities()
    }

    static func appDidEnterBackground() {
        LiveMediaDownloadManager.shared.resumeLiveActivities()
    }

    static func sceneDidForeground() {
        // purgeExpired() does manifest disk I/O (+ file deletion) under a lock;
        // keep it off the main thread (the store already posts its own change
        // notification back on main).
        DispatchQueue.global(qos: .utility).async {
            SavedMediaStore.shared.purgeExpired()
        }
        // Resume any downloads a Wi-Fi-only policy deferred, now that we're
        // foregrounding (possibly on Wi-Fi for the first time since they queued).
        Task { await LiveMediaDownloadManager.shared.resumePendingWiFiDownloads() }
    }

    static func readingListDidChange() {
        // purgeExpired() off the main thread — see sceneDidForeground.
        DispatchQueue.global(qos: .utility).async {
            SavedMediaStore.shared.purgeExpired()
        }
    }

    static func wifiBecameAvailable() {
        Task { await LiveMediaDownloadManager.shared.resumePendingWiFiDownloads() }
    }

    /// Downloader handles no articles — ereader sends are never pending here.
    static func retryPendingArticleSends() {}

    /// Overnight mail-fetch backstop for every unfinished media job, including
    /// a transfer whose server supplied resume data after an interruption.
    static func resumeUnfinishedMediaDownloads() async {
        await LiveMediaDownloadManager.shared.resumeUnfinishedDownloads()
    }

    static func attachBackgroundURLSessionHandler(_ completionHandler: @escaping () -> Void) {
        LiveMediaDownloadManager.shared.attachBackgroundCompletionHandler(completionHandler)
    }

    /// Downloader handles no products — no runner ⇒ AppDelegate never registers
    /// or schedules the price-refresh BGTask.
    static let priceRefreshRunner: (() async -> Int)? = nil

    #if DEBUG
    /// `-openArchive` is an article-app debug tool.
    static func debugArchiveReaderRoot(articleURL: URL) -> UIViewController? { nil }

    /// The kind-woven UI-test screen catalog compiles only into the central
    /// Luna app (the UI-test/screenshot host).
    static func uiTestRootViewController(named name: String) -> UIViewController? { nil }
    #endif
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

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
    /// A media save lands in both stores, so the watch covers both.
    private static let onboardingContentWatch = OnboardingContentWatch(
        changeNotifications: [.readingListChanged, .savedMediaChanged],
        storedIdentifiers: {
            Set(ReadingListStore.shared.items().map(\.id))
                .union(SavedMediaStore.shared.items().map(\.id))
        })

    /// Migration only — onboarding stores nothing (see `OnboardingLegacyDemoSave`).
    private static let legacyOnboardingDemoSave =
        DownloaderOnboardingDemoSave.legacyCleanup

    @MainActor
    static func install() {
        #if DEBUG
        AppOnboardingStore.shared.resetIfRequested()
        // Staged mode's catalogs — this app's kinds only (`claudedocs/staging.md`).
        SharedStageCatalog.install()
        MediaStageCatalog.install()
        #endif

        // The media kind pack — one call, shared verbatim with the Downloader's
        // share and action extensions (`MediaKindComposition`). Media needs no
        // web-processing pipeline stage (platform recognition is URL-only
        // classification), which is stated there rather than re-derived here.
        MediaKindComposition.install()
        // The media kind's CARD half, on the same principle — the one
        // definition the central app installs too (`CardKindPresenter.swift`).
        CardKindPresenters.media = MediaCardPresenter()
        // Post-save ingestion — metadata, thumbnail, auto-download handoff — is
        // the app-shell media ingestor handler.
        IngestorKindHandlers.media = MediaKindHandler()
        PasteboardSuggester.platformPreviewArt = { platform, itemID, urlString in
            await PlatformItemIngestor.shared.pasteboardPreviewArtData(
                platform: platform, itemID: itemID, urlString: urlString)
                .flatMap { UIImage(data: $0) }
        }
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

    // MARK: - Root UI shape

    /// The saved-media card deck in a bare nav controller — no audio
    /// mini-player host (read-aloud is an article-app feature). The deck itself
    /// is the shared host configured by `MediaCardDeck`; this app has no deck
    /// subclass of its own.
    @MainActor
    static func makeRootViewController() -> UIViewController {
        UINavigationController(rootViewController: MediaCardDeck.makeRoot())
    }

    @MainActor
    private static func makeCompletedRootViewController() -> UIViewController {
        UINavigationController(rootViewController: MediaCardDeck.makeRoot())
    }

    @MainActor
    static func makeSetupReplayRootViewController() -> UIViewController {
        makeCompletedRootViewController()
    }

    static func mainNavigationController(of root: UIViewController) -> UINavigationController? {
        root as? UINavigationController
    }

    static func openPriceTrackerAddSeller(
        itemID: UUID, navigationController: UINavigationController
    ) {}

    static func settingsCategories() -> [SettingsCategory] {
        [
            SettingsCategory(title: L10n.string("Common_downloads"), symbol: "arrow.down.circle") {
                DownloadsSettingsScreen()
            },
        ]
    }

    // MARK: - Lifecycle (called by AppDelegate/SceneDelegate at fixed points)

    /// Safari's in-page player queued these; the extension already resolved
    /// them, so the drain hands the assets straight to the download manager.
    /// Also runs at launch and on foreground, so a deep link that never arrived
    /// (a responder-chain open can silently fail) still lands its download.
    static func drainPendingResolvedMedia(returningToSource: Bool) {
        PendingResolvedMediaDownloads.drain(returningToSource: returningToSource)
    }

    static func appDidLaunch() {
        legacyOnboardingDemoSave.cleanup()
        drainPendingResolvedMedia(returningToSource: false)
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
        drainPendingResolvedMedia(returningToSource: false)
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

    /// The finished activity's Share button (`&share=1`): a downloaded local
    /// file becomes a concrete shareable copy with a human-readable name —
    /// exactly the export the card's own share menu and the App Intent handoff
    /// use. Anything else has no file to hand over and the route falls back to
    /// the plain open.
    static let mediaShareFileExporter: MediaShareFileExporting? = MediaShareFileExporting(
        export: { itemID in
            guard let item = SavedMediaStore.shared.items().first(where: { $0.id == itemID }),
                  case .localFile = item.storageState
            else { return nil }
            return await MediaAutoDownloader.exportFile(from: item)?.fileURL
        },
        discard: { MediaDownloadStorage.discardIntentExport(at: $0) })

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

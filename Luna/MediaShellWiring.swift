//
//  MediaShellWiring.swift
//  Luna
//
//  The media kind's half of the app shell. It installs every seam a
//  media-handling app needs at launch, and does the lifecycle work downloads
//  owe at each of `KindWiring`'s fixed points. Only the targets that link the
//  media kind compile this file — Luna and LunaDownloader. The other two
//  exclude it by membership exception, the same way they exclude
//  `Downloader/MediaCardPresenter.swift` and the rest of the media shell.
//
//  A `KindWiring+<App>` variant installs the media kind pack
//  (`MediaKindComposition`) and the media card presenter itself, then calls
//  the legs below. Nothing media-specific is written twice.
//

import LunaMediaDownload
import LunaModels
import LunaPlatforms
import LunaSaves
import LunaStorage
import UIKit

enum MediaShellWiring {

    @MainActor
    static func install() {
        // Post-save ingestion — metadata, thumbnail, auto-download handoff — is
        // the app-shell media ingestor handler.
        IngestorKindHandlers.media = MediaKindHandler()
        PasteboardSuggester.platformPreviewArt = PlatformPreviewArt()
        // Action Button intents hand recognized posts to the media downloader.
        MediaIntentHandoff.install()
        // The util card's inline "Store downloads …" line. Only an app that
        // downloads has anywhere to store, so only an app that links this module
        // installs the choice (`claudedocs/util-card.md`).
        MediaUtilCardStorageChoice.install()
        // URL Rescue's media leg: download engine-resolved assets directly.
        URLRescueWiring.mediaResolver = SocialMediaResolver()
        URLRescueWiring.mediaRescueStarter = ResolvedAssetRescueStarter()
        // The factory reset's media leg: a Live Activity outlives the process
        // that started it, so the wipe has to end them itself.
        FactoryReset.register(eraser: LiveActivityEraser())
        // A bulk import runs its own progress bar, and asks for Photos access at
        // the START of the run (`claudedocs/import-export.md`).
        LinkImportRunner.media = MediaImportLeg()
    }

    // MARK: - Lifecycle

    static func appDidLaunch() {
        drainPendingResolvedMedia(returningToSource: false)
        // A save or delete made by an extension happens in a different process,
        // so only a Darwin notification brings its `.savedMediaChanged` post
        // back here. The media card presenter asks for the same bridge when the
        // deck starts observing; both calls are the one guarded registration.
        SavedMediaStore.startObservingCrossProcessChanges()
        // Sweeps downloaded-but-never-saved media preview files orphaned when
        // a previous run was killed before its preview screen could clean up,
        // and applies the saved-media retention policy. Safe at launch, since
        // no preview is open yet; runs off the main thread so it doesn't
        // block startup.
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
        purgeExpiredSavedMedia()
    }

    static func savesDidChange() {
        purgeExpiredSavedMedia()
    }

    /// Downloads a Wi-Fi-only network policy deferred.
    static func resumePendingWiFiDownloads() {
        Task { await LiveMediaDownloadManager.shared.resumePendingWiFiDownloads() }
    }

    /// purgeExpired() does manifest disk I/O (+ file deletion) under a lock, so
    /// it stays off the main thread (the store posts its own change notification
    /// back on main).
    private static func purgeExpiredSavedMedia() {
        DispatchQueue.global(qos: .utility).async {
            SavedMediaStore.shared.purgeExpired()
        }
    }

    /// Downloads the assets Safari's in-page player queued. The extension
    /// already resolved them, so this hands them straight to the download
    /// manager. Also runs at launch and on foreground, so a deep link that
    /// never arrived — a responder-chain open can silently fail — still
    /// lands its download.
    static func drainPendingResolvedMedia(returningToSource: Bool) {
        PendingResolvedMediaDownloads.drain(returningToSource: returningToSource)
    }

    static func attachBackgroundURLSessionHandler(_ completionHandler: @escaping () -> Void) {
        LiveMediaDownloadManager.shared.attachBackgroundCompletionHandler(completionHandler)
    }

    /// Resolves the download Live Activity's tap-to-view link against the
    /// saved-media store. A downloaded local file centers the deck's card. A
    /// Photos-backed save opens Photos directly, reusing the card's own
    /// rosette mechanism. Still-downloading or unknown lands on the deck.
    static func deepLinkAction(forURLString urlString: String) -> MediaDeepLinkAction {
        guard let matched = SavedMediaStore.shared.matchingItem(forURLString: urlString) else { return .none }
        switch matched.storageState {
        case .localFile:
            return .center(matched.id)
        case .photosReference(let localIdentifier, _, _):
            MediaCardFactory.openInPhotos(localIdentifier: localIdentifier)
            return .openedExternally
        case .undownloaded:
            return .none
        }
    }

    /// The finished activity's Share button (`&share=1`). Anything with no file
    /// to hand over falls the route back to the plain open.
    static let shareFileExporter: (any MediaShareFileExporting)? = DownloadedFileExporter()
}

/// A recent URL's preview art, from the platform's own metadata fetcher.
private struct PlatformPreviewArt: PlatformPreviewArtProviding {
    func previewArt(
        platform: ContentPlatform, itemID: String?, urlString: String
    ) async -> UIImage? {
        await PlatformItemIngestor.shared.pasteboardPreviewArtData(
            platform: platform, itemID: itemID, urlString: urlString)
            .flatMap { UIImage(data: $0) }
    }
}

/// The finished activity's Share button (`&share=1`): a downloaded local file
/// becomes a concrete shareable copy with a human-readable name — exactly the
/// export the card's own share menu and the App Intent handoff use.
private struct DownloadedFileExporter: MediaShareFileExporting {
    func exportedFileURL(forItemID itemID: UUID) async -> URL? {
        guard let item = SavedMediaStore.shared.items().first(where: { $0.id == itemID }),
              case .localFile = item.storageState
        else { return nil }
        return await MediaAutoDownloader.exportFile(from: item)?.fileURL
    }

    func discardExportedFile(at fileURL: URL) {
        MediaDownloadStorage.discardIntentExport(at: fileURL)
    }
}

/// URL Rescue's media leg: the engine already resolved the assets, so this
/// downloads them without re-running platform resolution.
private struct ResolvedAssetRescueStarter: MediaRescueStarting {
    func startMediaRescue(
        sourceURLString: String, title: String?, assets: [MediaAsset]
    ) async -> Bool {
        await LiveMediaDownloadManager.shared.startWithResolvedAssets(
            sourceURLString: sourceURLString, title: title, assets: assets)
    }
}

/// The factory reset's media leg: a Live Activity outlives the process that
/// started it, so a wiped download would otherwise keep a lock-screen card
/// describing itself.
private struct LiveActivityEraser: FactoryResetErasing {
    func erase() async {
        await LiveMediaDownloadManager.shared.endAllActivities()
    }
}

/// The bulk import's media leg: the transfer watcher, the Live Activity alert
/// suspension that keeps an import from buzzing twice per link, and the one
/// Photos prompt asked for before the run starts.
private struct MediaImportLeg: LinkImportMediaHandling {
    func downloadState(
        forURLString urlString: String
    ) -> LinkImportRunner.MediaDownloadState? {
        MediaImportProgress.observe(urlString: urlString)
    }

    func setAlertsSuspended(_ suspended: Bool) {
        if suspended {
            LiveMediaDownloadManager.suspendActivityAlerts()
        } else {
            LiveMediaDownloadManager.resumeActivityAlerts()
        }
    }

    func preflightStorage(forURLStrings urlStrings: [String]) async {
        await MediaPhotosPreflight.requestAccessIfNeeded(for: urlStrings)
    }
}

/// Bridges `IngestorMediaHandling` to LunaPlatforms' `PlatformItemIngestor`.
private struct MediaKindHandler: IngestorMediaHandling {
    func ingestPlatformItem(
        _ item: SavedItem, platform: ContentPlatform, platformItemID: String?,
        store: SavesStore
    ) async {
        await PlatformItemIngestor.shared.ingest(
            item, platform: platform, platformItemID: platformItemID, store: store)
    }
}

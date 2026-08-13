//
//  MediaShellWiring.swift
//  Luna
//
//  The media kind's half of the app shell: every seam a media-handling app
//  installs at launch, and the lifecycle work downloads owe at each of
//  `KindWiring`'s fixed points. Compiled ONLY into the targets that link the
//  media kind (Luna, LunaDownloader) — the other two exclude this file by
//  membership exception, exactly as they exclude `Downloader/MediaCardPresenter
//  .swift` and the rest of the media shell.
//
//  A `KindWiring+<App>` variant installs the media KIND PACK
//  (`MediaKindComposition`) and the media CARD presenter itself, then calls the
//  legs below; nothing media-specific is written twice.
//

import LunaMediaDownload
import LunaModels
import LunaPlatforms
import LunaReadingList
import LunaStorage
import UIKit

enum MediaShellWiring {

    @MainActor
    static func install() {
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
        URLRescueWiring.mediaResolver = SocialMediaResolver()
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

    // MARK: - Lifecycle

    static func appDidLaunch() {
        drainPendingResolvedMedia(returningToSource: false)
        // A save or delete made by an extension happens in a different process,
        // so only a Darwin notification brings its `.savedMediaChanged` post
        // back here. The media card presenter asks for the same bridge when the
        // deck starts observing; both calls are the one guarded registration.
        SavedMediaStore.startObservingCrossProcessChanges()
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
        purgeExpiredSavedMedia()
    }

    static func readingListDidChange() {
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

    /// Safari's in-page player queued these; the extension already resolved
    /// them, so the drain hands the assets straight to the download manager.
    /// Also runs at launch and on foreground, so a deep link that never arrived
    /// (a responder-chain open can silently fail) still lands its download.
    static func drainPendingResolvedMedia(returningToSource: Bool) {
        PendingResolvedMediaDownloads.drain(returningToSource: returningToSource)
    }

    static func attachBackgroundURLSessionHandler(_ completionHandler: @escaping () -> Void) {
        LiveMediaDownloadManager.shared.attachBackgroundCompletionHandler(completionHandler)
    }

    /// The download Live Activity's tap-to-view link, resolved against the
    /// saved-media store: a downloaded local file centers the deck's card;
    /// a Photos-backed save opens Photos directly (reusing the card's
    /// own rosette mechanism); still-downloading or unknown lands on the deck.
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

    /// The finished activity's Share button (`&share=1`): a downloaded local
    /// file becomes a concrete shareable copy with a human-readable name —
    /// exactly the export the card's own share menu and the App Intent handoff
    /// use. Anything else has no file to hand over and the route falls back to
    /// the plain open.
    static let shareFileExporter: MediaShareFileExporting? = MediaShareFileExporting(
        export: { itemID in
            guard let item = SavedMediaStore.shared.items().first(where: { $0.id == itemID }),
                  case .localFile = item.storageState
            else { return nil }
            return await MediaAutoDownloader.exportFile(from: item)?.fileURL
        },
        discard: { MediaDownloadStorage.discardIntentExport(at: $0) })
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

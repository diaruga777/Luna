//
//  StageCatalog+Media.swift
//  Luna
//
//  Media-kind stages. Compiled ONLY into the targets that link the media kind
//  (Luna, LunaDownloader); the other two exclude this file by membership
//  exception, as they already exclude `Downloader/MediaCardFactory.swift`.
//

#if DEBUG

import LunaMediaDownload
import LunaModels
import UIKit

enum MediaStageCatalog {

    @MainActor
    static func install() {
        StageRegistry.register(deckStages + downloadStateStages + screenStages)
    }

    /// One URL, used by both halves of every media fixture: the reading-list
    /// row and the `SavedMediaStore` row are joined by URL STRING, and a
    /// mismatch renders the generic link card instead of the media one.
    private static let videoURL = "https://youtube.com/watch?v=stage-video"
    private static let imageURL = "https://instagram.com/p/stage-image"

    // MARK: - The deck

    @MainActor
    private static var deckStages: [StageDescriptor] {
        [
            StageDescriptor(
                id: "deck.media.empty", screen: "Card deck", variant: "no media saved",
                summary: "The media deck with nothing in it.",
                kind: .media,
                seed: {
                    StageFixtures.completeOnboarding()
                    StageFixtures.seedEmpty()
                    SavedMediaStore.shared.wipeForTesting()
                }),
            StageDescriptor(
                id: "deck.media.populated", screen: "Card deck", variant: "saved media",
                summary: "A downloaded image beside an undownloaded video — the two shapes "
                    + "a media card takes.",
                kind: .media,
                seed: {
                    StageFixtures.completeOnboarding()
                    seedMediaLibrary()
                }),
        ]
    }

    /// Seeds both halves: the reading-list rows the deck pages over, and the
    /// `SavedMediaStore` rows the media presenter joins to them.
    @MainActor
    private static func seedMediaLibrary() {
        SavedMediaStore.shared.wipeForTesting()
        StageFixtures.seed([
            StageFixtures.platformPost(
                seed: "stage-image", url: imageURL, title: "A Saved Photo",
                platform: .instagram, hoursAgo: 1),
            StageFixtures.platformPost(
                seed: "stage-video", url: videoURL, title: "A Short Film About Rain",
                platform: .youtube, channel: "Kurzgesagt", daysAgo: 1),
        ])

        var items = [undownloadedVideo()]
        // A local-file row needs the file to actually be there — the card reads
        // it — so generate one rather than commit a binary staged mode alone uses.
        let fileName = "stage-image.jpg"
        if StageFixtures.writeSampleImage(
            named: fileName, in: SavedMediaStore.shared.mediaDirectory) != nil {
            items.insert(
                SavedMediaItem(
                    id: ReadingListItem.deterministicUUID(from: "stage-media-image"),
                    sourceURLString: imageURL, title: "A Saved Photo",
                    dateSaved: StageFixtures.ago(hours: 1), kind: .image,
                    storageState: .localFile(fileName: fileName), thumbnailFileName: nil,
                    platform: .instagram, platformItemID: "stage-image", creator: "creator"),
                at: 0)
        }
        SavedMediaStore.shared.seedForTesting(items: items)
    }

    private static func undownloadedVideo() -> SavedMediaItem {
        SavedMediaItem(
            id: ReadingListItem.deterministicUUID(from: "stage-media-video"),
            sourceURLString: videoURL, title: "A Short Film About Rain",
            dateSaved: StageFixtures.ago(days: 1), kind: .video,
            storageState: .undownloaded, thumbnailFileName: nil,
            platform: .youtube, platformItemID: "stage-video", creator: "Kurzgesagt")
    }

    // MARK: - Download states

    /// The four states a transfer passes through, each held still. A real
    /// download is through all of them inside a few seconds, so these are built
    /// from a described `DownloaderJobSnapshot` rather than by starting one —
    /// and because staged mode posts no progress notifications, they stay.
    @MainActor
    private static var downloadStateStages: [StageDescriptor] {
        [
            StageDescriptor(
                id: "card.media.queued", screen: "Media card", variant: "queued",
                summary: "Saved but not downloaded: the download glyph, no status bar.",
                kind: .media,
                make: { downloadCard(snapshot: nil) }),
            StageDescriptor(
                id: "card.media.resolving", screen: "Media card", variant: "resolving",
                summary: "Finding the asset behind the post. A message but no percentage — "
                    + "a fraction is only honest once bytes are moving.",
                kind: .media,
                make: {
                    downloadCard(snapshot: snapshot(
                        phase: .resolving, progress: 0, message: "Finding the video…"))
                }),
            StageDescriptor(
                id: "card.media.downloading", screen: "Media card", variant: "in progress",
                summary: "Mid-transfer at 45%: the embedded glass status bar with its "
                    + "horizon progress.",
                kind: .media,
                make: {
                    downloadCard(snapshot: snapshot(
                        phase: .downloading, progress: 0.45, message: "Downloading…"))
                }),
            StageDescriptor(
                id: "card.media.waiting", screen: "Media card", variant: "waiting for Wi-Fi",
                summary: "Deferred by the Wi-Fi-only policy — status, no percentage, and the "
                    + "transfer resumes the instant Wi-Fi returns.",
                kind: .media,
                make: {
                    downloadCard(snapshot: snapshot(
                        phase: .waiting, progress: 0, message: "Waiting for Wi‑Fi"))
                }),
            StageDescriptor(
                id: "card.media.failed", screen: "Media card", variant: "failed",
                summary: "A download that failed: red status, no progress, and the download "
                    + "glyph back for a retry.",
                kind: .media,
                make: {
                    downloadCard(snapshot: snapshot(
                        phase: .failed, progress: 0, message: "Download failed",
                        failureKind: .other))
                }),
            StageDescriptor(
                id: "card.media.no-media", screen: "Media card", variant: "nothing to download",
                summary: "The one failure that offers the AI rescue: the page held no media "
                    + "this app could recognise.",
                kind: .media,
                make: {
                    downloadCard(
                        snapshot: snapshot(
                            phase: .failed, progress: 0, message: "No media found",
                            failureKind: .noMedia),
                        offersRescue: true)
                }),
            StageDescriptor(
                id: "card.media.finished", screen: "Media card", variant: "saved",
                summary: "The transfer done and the file saved.",
                kind: .media,
                make: {
                    downloadCard(snapshot: snapshot(
                        phase: .saving, progress: 1, message: "Saving to Photos…"))
                }),
        ]
    }

    private static func snapshot(
        phase: DownloaderJobPhase, progress: Double, message: String,
        failureKind: DownloaderJobSnapshot.FailureKind? = nil
    ) -> DownloaderJobSnapshot {
        DownloaderJobSnapshot(
            sourceURLString: videoURL, title: "A Short Film About Rain",
            phase: phase, progress: progress, message: message,
            thumbnailFileName: nil, failureKind: failureKind)
    }

    @MainActor
    private static func downloadCard(
        snapshot: DownloaderJobSnapshot?, offersRescue: Bool = false
    ) -> UIViewController {
        let card = UndownloadedMediaCardContentViewController(
            item: undownloadedVideo(), download: {},
            rescue: offersRescue ? {} : nil)
        card.stagedSnapshot = snapshot
        return StageCardHostViewController(card: card)
    }

    // MARK: - Screens

    @MainActor
    private static var screenStages: [StageDescriptor] {
        [
            StageDescriptor(
                id: "share.media-saved", screen: "Extension media screen", variant: "pending",
                summary: "What a saved post shows in the share/action extension before any "
                    + "download starts. Hosted in-app — a simulator cannot drive the share sheet.",
                kind: .media,
                seed: { AutoDownloadSettings.autoDownloadMediaInPreview = false },
                make: {
                    UINavigationController(
                        rootViewController: SavedNonTextualViewController(
                            articleURLString: "https://x.com/user/status/123",
                            showsSystemShare: true, onDone: {}))
                }),
            StageDescriptor(
                id: "util.download-storage", screen: "Util card",
                variant: "storage unanswered",
                summary: "The inline \"Store downloads\" line above the setup buttons, on a "
                    + "completed card whose recents it stands down. Only the two apps that "
                    + "download can offer it.",
                kind: .media,
                seed: { StageFixtures.seedEmpty() },
                make: {
                    SharedStageCatalog.utilCard(
                        showsOnboarding: false,
                        recents: [],
                        storageChoice: StageDownloadStorageChoice())
                }),
            StageDescriptor(
                id: "settings.downloads", screen: "Settings → Downloads", variant: "default",
                summary: "Auto-download, Wi-Fi-only, and save-to-Photos.",
                kind: .media,
                make: {
                    UINavigationController(rootViewController: DownloadsSettingsScreen())
                }),
        ]
    }
}

/// A storage choice that answers from memory. The real one
/// (`MediaUtilCardStorageChoice`) reads the App Group and prompts PhotoKit —
/// neither of which a stage may depend on if its screenshot is to be the same
/// every time.
@MainActor
private final class StageDownloadStorageChoice: DownloadStorageChoosing {
    var isUnanswered = true
    var usesPhotos = true

    func chooseInLuna() { usesPhotos = false }

    func choosePhotos(completion: @escaping (DownloadStoragePhotosOutcome) -> Void) {
        usesPhotos = true
        completion(.granted)
    }
}

#endif

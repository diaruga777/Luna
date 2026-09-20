//
//  PlatformItemIngestor.swift
//  LunaPlatforms
//

import LunaMediaDownload
import LunaModels
import LunaStorage
import Foundation

/// Media-kind ingestion, extracted from `SavesIngestor` so only
/// media-handling apps carry the platform-metadata and auto-download machinery.
/// The app shell installs this behind `IngestorKindHandlers.media` (via a thin
/// adapter in its `KindWiring` variant).
public final class PlatformItemIngestor {
    public static let shared = PlatformItemIngestor()

    public init() {}

    /// Ingests a recognized platform item: best-effort metadata (title/thumbnail
    /// via the module's optional fetcher), then marks `.ready`.
    /// Recognized platform items NEVER enter `.failed` — they render from a logo
    /// + deep link even when metadata is unavailable.
    public func ingest(
        _ item: SavedItem, platform: ContentPlatform, platformItemID: String?,
        store: SavesStore
    ) async {
        // A row that is ALREADY ready is having its content replaced — a
        // recovery file for a save that downloaded the wrong asset
        // (`claudedocs/llm-handoff.md`). The library row and its file describe
        // that asset, and the download gate below answers "already downloaded"
        // while they stand, so they go first and a fresh transfer starts.
        if item.state == .ready {
            await MainActor.run { MediaSavedContents.discard(forURLString: item.urlString) }
        }

        let match = PlatformMatch(platform: platform, itemID: platformItemID)
        let metadata = await platformMetadata(
            platform: platform, itemID: platformItemID, urlString: item.urlString)

        var thumbnailFileName: String?
        if let data = metadata?.thumbnailData, !data.isEmpty {
            let fileName = "\(item.id.uuidString)-thumb.jpg"
            try? data.write(
                to: store.articlesDirectory.appendingPathComponent(fileName), options: .atomic)
            thumbnailFileName = fileName
        }

        _ = store.savePlatformMetadata(
            platform: match.platform,
            platformItemID: match.itemID,
            title: metadata?.title,
            thumbnailFileName: thumbnailFileName,
            for: item.id)

        // Downloader normally uses the system-owned background job. App Intents
        // own their media handoff after the save result is known so the user's
        // setting can choose awaited file return or the same Live Activity path
        // without racing a second transfer from this ingestion task.
        if MediaAutoDownloader.isRunningInDownloader,
           item.effectiveCaptureSource != .appIntent {
            _ = await LiveMediaDownloadManager.shared.start(
                urlString: item.urlString, title: item.title, ownership: .downloader)
        } else if item.effectiveCaptureSource != .appIntent {
            await MediaAutoDownloader.runIfEnabledAwaiting(forURLString: item.urlString)
        }
    }

    /// Best-effort preview art for a pasteboard platform candidate — the
    /// media-handling apps' `KindWiring` installs this behind
    /// `PasteboardSuggester.platformPreviewArt`.
    public func pasteboardPreviewArtData(
        platform: ContentPlatform, itemID: String?, urlString: String
    ) async -> Data? {
        await platformMetadata(platform: platform, itemID: itemID, urlString: urlString)?.thumbnailData
    }

    /// Best-effort platform metadata for preview UI as well as persisted media
    /// saves. Keeping this one dispatch point prevents the two surfaces from
    /// disagreeing about which platforms can supply a title or thumbnail.
    public func platformMetadata(
        platform: ContentPlatform, itemID: String?, urlString: String
    ) async -> PlatformMetadata? {
        let match = PlatformMatch(platform: platform, itemID: itemID)
        return await PlatformRegistry.shared.module(for: match.platform)?
            .metadataFetcher?.fetchMetadata(for: match, urlString: urlString)
    }
}

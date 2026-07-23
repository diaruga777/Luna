//
//  KindWiring+Downloader.swift
//  Luna
//
//  Per-app composition root: registers exactly the per-kind processors and
//  ingestor handlers this app's target links. EXACTLY ONE KindWiring variant is
//  compiled into each app target (the other variants are excluded via the
//  synchronized group's per-target membership exceptions) — the registries
//  mirror the link set.
//

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
        PasteboardSuggester.platformPreviewArt = { platform, itemID, urlString in
            await PlatformItemIngestor.shared.pasteboardPreviewArtData(
                platform: platform, itemID: itemID, urlString: urlString)
                .flatMap { UIImage(data: $0) }
        }
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

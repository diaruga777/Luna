//
//  KindWiring+Luna.swift
//  Luna
//
//  Per-app composition root: registers exactly the per-kind processors and
//  ingestor handlers this app's target links. EXACTLY ONE KindWiring variant is
//  compiled into each app target (the other variants are excluded via the
//  synchronized group's per-target membership exceptions) — the registries
//  mirror the link set.
//

import LunaArticleIngest
import LunaHTMLClassification
import LunaIngest
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
        PasteboardSuggester.platformPreviewArt = { platform, itemID, urlString in
            await PlatformItemIngestor.shared.pasteboardPreviewArtData(
                platform: platform, itemID: itemID, urlString: urlString)
                .flatMap { UIImage(data: $0) }
        }
        EmailShareCenter.priceGraphSnapshot = { PriceGraphEmailSnapshot.jpegData(for: $0) }
        // The central Luna app is the only surface whose card deck contains
        // non-article cards; give them their tap routing.
        NonArticleCardOpening.install()
    }
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

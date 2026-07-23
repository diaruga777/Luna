//
//  KindWiring+Reader.swift
//  Luna
//
//  Per-app composition root: registers exactly the per-kind processors and
//  ingestor handlers this app's target links. EXACTLY ONE KindWiring variant is
//  compiled into each app target (the other variants are excluded via the
//  synchronized group's per-target membership exceptions) — the registries
//  mirror the link set.
//

import LunaArticleIngest
import LunaIngest
import LunaModels
import LunaReaderUI
import LunaReadingList
import LunaSend
import LunaStorage
import Foundation

enum KindWiring {
    static func install() {
        IngestKindProcessors.article = ArticleIngestProcessor()
        IngestorKindHandlers.article = ArticleKindHandler()
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

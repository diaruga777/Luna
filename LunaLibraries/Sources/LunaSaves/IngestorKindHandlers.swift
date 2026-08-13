//
//  IngestorKindHandlers.swift
//  LunaSaves
//

import LunaHTMLClassification
import LunaModels
import LunaStorage
import Foundation

/// Article-kind ingestion and persistence behavior behind `SavesIngestor`.
/// It covers everything the ingestor needs that would otherwise drag
/// article-only modules (LunaReaderUI, LunaArchiveReader, LunaDocuments,
/// LunaSend) into every app. The heavy lifting lives in
/// `LunaReaderUI.ArticleIngestHandler`. The app shell's adapter bridges the
/// send methods to `ArticleSendCoordinator`, since LunaReaderUI must not
/// depend on LunaSend.
public protocol IngestorArticleHandling {
    /// Persists a readable article: downloads its images + cover art, saves the
    /// content, and flips ready (then finishes non-critical artifacts async).
    func persistArticle(
        _ content: ArticleContent, html: String, for item: SavedItem,
        url: URL, store: SavesStore) async
    /// Document ingestion: parse the imported file (stored at
    /// `Articles/<id>-source.<type>`) into article content.
    func ingestDocument(_ item: SavedItem, store: SavesStore) async
    /// Repairs every ready web page that lacks a `.webarchive` (see
    /// `SavesIngestor.backfillMissingWebArchives`).
    func backfillMissingWebArchives(store: SavesStore)
    /// Repairs ready and locked web articles that have no row thumbnail (see
    /// `SavesIngestor.backfillMissingThumbnails`).
    func backfillMissingThumbnails(store: SavesStore)
    /// A saved item just flipped `.ready` — kicks the auto-send pipeline
    /// (Kindle/ereaders). Bridged to `ArticleSendCoordinator.articleBecameReady`.
    func articleBecameReady(_ item: SavedItem)
    /// Eagerly preloads the current pasteboard candidate's links (see
    /// `PreloadCoordinator.preloadPasteboard`).
    func preloadPasteboard(content: ArticleContent, sourceURL: URL)
    /// Destinations that are configured and in double-save mode right now.
    func doubleSaveDestinationIDs() -> [String]
    /// Sends an article to one ereader destination (by id).
    func sendToDestination(_ item: SavedItem, destinationID: String) async
    /// Whether sends can actually go out to this destination.
    func isDestinationConfigured(_ destinationID: String) -> Bool
}

/// Media-kind ingestion behavior: best-effort platform metadata + the
/// auto-download handoff. Implemented over `LunaPlatforms.PlatformItemIngestor`.
public protocol IngestorMediaHandling {
    /// Ingests a recognized platform item (video or social post): best-effort
    /// metadata, then marks `.ready`. Never enters `.failed`.
    func ingestPlatformItem(
        _ item: SavedItem, platform: ContentPlatform, platformItemID: String?,
        store: SavesStore) async
}

/// Product-kind ingestion behavior: turn a detected product page into a price
/// tracker (merging into an existing tracker for the same product when one
/// matches). Implemented over `LunaPriceUI.ProductTrackerIngestor`.
public protocol IngestorProductHandling {
    func ingestProductTracker(
        _ item: SavedItem, url: URL, product: ProductInfo,
        store: SavesStore) async
}

/// The per-kind ingestor handler registry — the store-writing counterpart of
/// `LunaIngest.IngestKindProcessors`. Each app's composition root (its
/// `KindWiring` variant) registers exactly the handlers for the kinds it
/// handles: Reader registers article, Downloader registers media, Price
/// Tracker registers product, and the central Luna app registers all three.
/// So `LunaSaves` itself carries no foreign-kind dependencies. A classified
/// outcome only ever reaches the presenter after the `SurfaceSupport` gate, so
/// a missing handler for a presented case is a programming error, not a
/// user-reachable state.
public enum IngestorKindHandlers {
    public static var article: IngestorArticleHandling?
    public static var media: IngestorMediaHandling?
    public static var product: IngestorProductHandling?
}

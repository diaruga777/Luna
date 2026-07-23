//
//  IngestKindProcessors.swift
//  ReaderKit
//

import LunaFetch
import LunaHTMLClassification
import LunaModels
import Foundation

/// Article-kind pipeline processing: resolve a fetched page into a readable
/// article (silent bypass strategies included). Implemented by
/// `LunaArticleIngest.ArticleIngestProcessor`; the pipeline itself only knows
/// this seam, so targets that don't link the article module carry none of the
/// resolution/bypass code.
public protocol ArticleIngestProcessing {
    /// Returns `.article`, `.needsArchive`, or `.failed` for a page the
    /// classifier routed to the article path. `directHTML` is the pipeline's
    /// single shared fetch (or the surface's prefetch).
    func process(
        url: URL, directHTML: String?, trustsPrefetchedHTML: Bool, fetcher: HTMLFetching
    ) async -> Outcome
}

/// Product-kind pipeline processing: extract the mandatory-price product
/// metadata for a page classified/detected as a product. Implemented by
/// `LunaPriceIngest.ProductIngestProcessor`.
public protocol ProductIngestProcessing {
    /// nil when no trustworthy price was found — the pipeline then falls
    /// through to the article path (matching the pre-split behavior).
    func extract(
        url: URL, html: String, render: ((URL) async -> String?)?
    ) async -> ProductInfo?
}

/// The per-kind processor registry — the runtime face of each target's LINK
/// SET. A target's composition root registers exactly the processors its app
/// handles (Reader: article; Price Tracker: product; the central Luna app:
/// both; Downloader: neither — media needs no web processing). A classified
/// kind with no registered processor becomes `Outcome.unsupported(owner:)`,
/// which every surface drops with the generic error (`SurfaceSupport`).
public enum IngestKindProcessors {
    public static var article: ArticleIngestProcessing?
    public static var product: ProductIngestProcessing?
}

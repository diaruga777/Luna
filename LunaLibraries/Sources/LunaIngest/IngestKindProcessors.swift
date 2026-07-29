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

/// Social-post TEXT processing: a long-form post on a social platform (an X
/// Article, a long single post, or the poster's own chained thread) read as a
/// reader article instead of an opaque social card. Implemented by
/// `LunaArticleIngest.XPostIngestProcessor`.
///
/// This is the one kind whose routing needs a network round-trip to decide: URL
/// classification can tell that a link is an X post, but not whether that post
/// holds 40 characters or 4,000. So the pipeline offers every recognized social
/// post to this seam and takes an article only when one comes back — a short
/// post is declined and stays `.social`, unchanged from before.
public protocol SocialTextIngestProcessing {
    /// Reader content for the post, or nil when there is no long-form text to
    /// read (a short post, an unreachable API, an unsupported platform). Nil is
    /// the ordinary case and is never an error: the pipeline falls back to
    /// `.social`.
    func article(platform: ContentPlatform, itemID: String?, url: URL) async -> SocialTextArticle?
}

/// A social post read as an article: the extracted content plus a rendering of
/// it as HTML.
///
/// The `html` is not the platform's markup — an unauthenticated fetch of an X
/// post returns only a login shell — but a self-contained document built FROM
/// the extracted post. It exists because the article artifact stages downstream
/// consume source HTML rather than content: `ArticleCoverThumbnail` reads an
/// `og:image` from it for the card thumbnail, and `WebArchiveCapturer` archives
/// it. Handing those stages an empty string would send the archiver to capture
/// the platform's login wall instead, so the post renders its own source.
public struct SocialTextArticle {
    public let content: ArticleContent
    public let html: String

    public init(content: ArticleContent, html: String) {
        self.content = content
        self.html = html
    }
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
    /// Registered by article-handling apps only (Reader + central Luna). Absent,
    /// social posts classify exactly as they did before this seam existed.
    public static var socialText: SocialTextIngestProcessing?
}

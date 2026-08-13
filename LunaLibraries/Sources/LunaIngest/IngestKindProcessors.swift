//
//  IngestKindProcessors.swift
//  ReaderKit
//

import LunaFetch
import LunaHTMLClassification
import LunaModels
import Foundation

/// Article-kind processing: resolves a fetched page into a readable article,
/// including silent bypass strategies. `LunaArticleIngest.ArticleIngestProcessor`
/// implements this protocol. The pipeline knows only this seam, so a target
/// that does not link the article module carries none of the resolution or
/// bypass code.
public protocol ArticleIngestProcessing {
    /// Returns `.article`, `.needsArchive`, or `.failed` for a page the
    /// classifier routed to the article path. `directHTML` is the pipeline's
    /// single shared fetch, or the surface's prefetch.
    func process(
        url: URL, directHTML: String?, trustsPrefetchedHTML: Bool, fetcher: HTMLFetching
    ) async -> Outcome
}

/// Product-kind processing: extracts the mandatory-price product metadata for
/// a page classified or detected as a product.
/// `LunaPriceIngest.ProductIngestProcessor` implements this protocol.
public protocol ProductIngestProcessing {
    /// Returns nil when no trustworthy price was found. The pipeline then
    /// falls through to the article path.
    func extract(url: URL, html: String) async -> ProductInfo?
}

/// Social-post text processing: reads a long-form post on a social platform
/// (an X Article, a long single post, or the poster's own chained thread) as
/// a reader article instead of an opaque social card.
/// `LunaArticleIngest.XPostIngestProcessor` implements this protocol.
///
/// This is the one kind whose routing needs a network round trip to decide.
/// URL classification can tell that a link is an X post, but not whether that
/// post holds 40 characters or 4,000. The pipeline offers every recognized
/// social post to this seam and takes an article only when one comes back. A
/// short post is declined and stays `.social`.
public protocol SocialTextIngestProcessing {
    /// Returns reader content for the post, or nil when there is no long-form
    /// text to read (a short post, an unreachable API, an unsupported
    /// platform). Nil is the ordinary case and is never an error: the
    /// pipeline falls back to `.social`.
    func article(platform: ContentPlatform, itemID: String?, url: URL) async -> SocialTextArticle?
}

/// A social post read as an article: the extracted content plus a rendering of
/// it as HTML.
///
/// The `html` is not the platform's markup. An unauthenticated fetch of an X
/// post returns only a login shell, so this is a self-contained document built
/// from the extracted post instead. Downstream article stages consume source
/// HTML rather than content: `ArticleCoverThumbnail` reads an `og:image` from
/// it for the card thumbnail, and `WebArchiveCapturer` archives it. An empty
/// string here would send the archiver to capture the platform's login wall,
/// so the post renders its own source instead.
public struct SocialTextArticle {
    public let content: ArticleContent
    public let html: String

    public init(content: ArticleContent, html: String) {
        self.content = content
        self.html = html
    }
}

/// The per-kind processor registry: the runtime face of each target's link
/// set. A target's composition root registers exactly the processors its app
/// handles (Reader: article; Price Tracker: product; the central Luna app:
/// both; Downloader: neither, since media needs no web processing). A
/// classified kind with no registered processor becomes
/// `Outcome.unsupported(owner:)`, which every surface drops with the generic
/// error (`SurfaceSupport`).
public enum IngestKindProcessors {
    public static var article: ArticleIngestProcessing?
    public static var product: ProductIngestProcessing?
    /// Registered by article-handling apps only (Reader and the central Luna
    /// app). When absent, a social post is never promoted to an article.
    public static var socialText: SocialTextIngestProcessing?
}

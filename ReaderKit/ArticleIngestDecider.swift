//
//  ArticleIngestDecider.swift
//  ReaderKit
//

import Foundation

/// The classification of a saved web URL after running the WHOLE shared decision
/// pipeline (product detection → article resolution → the bypass gate). Modeled so
/// invalid states can't arise: a readable article always carries its content + source
/// HTML, a price tracker always carries a fully-priced `ProductInfo`, a needs-archive
/// result always carries a non-empty title.
enum ArticleIngestDecision: Equatable {
    /// A readable article was obtained (directly or via a silent bypass strategy).
    case article(ArticleContent, html: String)
    /// The page is a product with a fetchable price — route to price tracking, never
    /// the paywall/archive flow.
    case priceTracker(ProductInfo, html: String)
    /// A genuine paywall we couldn't read silently, but we have a title to park it
    /// under. The caller opens the interactive archive reader (CAPTCHA) for this.
    case needsArchive(title: String)
    /// Nothing usable on an ordinary site — a genuine failure.
    case failed
}

/// The SINGLE shared decision routine used identically by the main-app ingestor
/// (`ReadingListIngestor.ingest`) AND both share-sheet extensions
/// (`ShareViewController` inline path, `ShareReaderViewController`). Given a URL (and
/// optionally already-fetched HTML), it runs the entire pipeline — product detection,
/// then article resolution through the silent bypass strategies, then the GOAL-1
/// `BypassGate` — and returns one unified `ArticleIngestDecision`. Callers then differ
/// ONLY in presentation (the app updates list state; the extensions show the inline
/// reader / archive reader / checkmark).
///
/// Dependency-free (no `UIApplication`/CloudKit) so it compiles in the extension
/// targets. Pure of state mutation — it never writes the store. Tested by
/// `ArticleIngestDeciderTests` (parity across entry points via a mock fetcher).
enum ArticleIngestDecider {

    /// Runs the full pipeline for `url`. `prefetchedHTML`, when supplied, is the
    /// direct page HTML the caller already fetched (the share extension fetches it
    /// once for product detection); it's reused so we don't double-fetch.
    ///
    /// Order (identical to the main-app ingestor):
    /// 1. Product detection — a product page with a fetchable price becomes a
    ///    `.priceTracker` and is NEVER paywall-bypassed.
    /// 2. Article resolution — direct fetch + silent bypass strategies, gated.
    /// 3. Classification — `.article` on success; on a paywall, `.needsArchive`
    ///    (with a real or guessed title) for a hard-paywall host / archive URL,
    ///    else `.failed` for an ordinary unreachable page.
    /// - `render`: the bounded WebView render tier for the product price extractor.
    ///   DEFAULT nil ⇒ the render tier is structurally unreachable, so a product page
    ///   whose price is JS-only resolves to no-price → article (never a spinning
    ///   WebView). App extensions take the default; the main app passes a real renderer
    ///   only because it can afford a `WKWebView`.
    static func decide(
        url: URL,
        prefetchedHTML: String? = nil,
        skipProductDetection: Bool = false,
        fetcher: HTMLFetching = ArticleFetcher(),
        extractor: ArticleExtractor = ArticleExtractor(),
        productDetector: ProductPageDetector = ProductPageDetector(),
        metadataExtractor: ProductMetadataExtractor = ProductMetadataExtractor(),
        render: ((URL) async -> String?)? = nil,
        runner: BypassRunning? = nil,
        replayLog: ((EventKind) async -> Void)? = nil
    ) async -> ArticleIngestDecision {
        // (1) Product detection runs BEFORE any paywall/archive treatment, so a
        // product page is routed to price tracking and never paywall-bypassed. The
        // mandatory price decides whether a candidate actually becomes a tracker — a
        // page with no resolvable price falls through to the article path. ONE parse,
        // ONE price source (the extractor's per-host rule table, else generic fallback).
        // `skipProductDetection` forces the article path (the "Read instead" override).
        let directHTML: String?
        if skipProductDetection {
            directHTML = prefetchedHTML
        } else {
            if let prefetchedHTML {
                directHTML = prefetchedHTML
            } else {
                directHTML = try? await fetcher.fetchHTML(from: url)
            }
            if let html = directHTML,
               productDetector.detect(urlString: url.absoluteString, html: html) != nil,
               let metadata = await metadataExtractor.extract(url: url, html: html, render: render) {
                return .priceTracker(ProductInfo(
                    name: metadata.name, priceAmount: metadata.price.amount,
                    priceCurrency: metadata.price.currency, imageURL: metadata.imageURL,
                    brand: metadata.brand, productID: metadata.productID), html: html)
            }
        }

        // (2) Resolve the article: direct fetch (reusing `directHTML`), then the
        // silent bypass strategies the gate allows. The gate inside the selector
        // blocks bypass for non-paywalled pages.
        let resolution = await ArticleResolver.resolve(
            url: url, prefetchedHTML: directHTML, fetcher: fetcher,
            extractor: extractor, runner: runner, replayLog: replayLog)

        // (3) Map the resolution to the unified decision.
        switch resolution {
        case let .readable(content, html):
            return .article(content, html: html)
        case let .paywalled(title):
            return .needsArchive(title: title)
        case .unreadable:
            // A hard-paywall host or an already-archived URL can still be read via its
            // archive snapshot behind a user-solved CAPTCHA — park it for the archive
            // reader. Only a truly unreachable ordinary page is a genuine failure.
            if ArticleFetcher.isHardPaywallHost(url) || ArticleFetcher.isArchiveTodayURL(url) {
                return .needsArchive(title: ArticleFetcher.articleTitleGuess(from: url))
            }
            return .failed
        }
    }
}

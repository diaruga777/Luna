//
//  IngestPipeline.swift
//  ReaderKit
//

import LunaFetch
import LunaHTMLClassification
import LunaURLClassification
import LunaModels
import Foundation

/// Everything a surface knows about an incoming save, handed to the ONE shared
/// pipeline. The `source` travels with the input so per-surface presentation
/// policy (interactive price UI vs silent save) is data, not branching scattered
/// across view controllers. The URL is unwrapped + classified identically for
/// every source — only presentation differs afterward.
public struct IngestInput {
    /// The incoming URL, exactly as the surface received it (may still be an
    /// `fbrpc://` deep link or a news-aggregator wrapper — the pipeline unwraps it
    /// once, up front, so every surface gets the same unwrap).
    public let url: URL
    /// Where the save came from. Drives presentation policy, never the decision.
    public let source: CaptureSource
    /// A save-time document type flag (pdf/epub/…) when the surface imported a file
    /// rather than a web URL — always wins classification (`.document`).
    public let documentType: String?
    /// Page HTML the surface already fetched, reused so the pipeline doesn't refetch.
    public let prefetchedHTML: String?
    /// The "Read instead" override — forces the article path even for a product page.
    public let forceArticle: Bool
    /// The `prefetchedHTML` is the already-unlocked, on-screen article DOM captured in
    /// Safari (the "Read in Luna" hand-off), so the publisher's stale schema.org lock
    /// (`isAccessibleForFree:false`, still in the page's JSON-LD after a client-side
    /// unlock) must NOT re-reject it as paywalled. Only the Safari hand-off sets this;
    /// every other prefetch (share sheet, product pages) keeps the full paywall gate.
    public let trustsPrefetchedHTML: Bool

    public init(
        url: URL,
        source: CaptureSource,
        documentType: String? = nil,
        prefetchedHTML: String? = nil,
        forceArticle: Bool = false,
        trustsPrefetchedHTML: Bool = false
    ) {
        self.url = url
        self.source = source
        self.documentType = documentType
        self.prefetchedHTML = prefetchedHTML
        self.forceArticle = forceArticle
        self.trustsPrefetchedHTML = trustsPrefetchedHTML
    }
}

/// The SINGLE unified result every surface receives from `IngestPipeline.process`.
/// Exhaustive over every kind a save can become, so the compiler forces each
/// `OutcomePresenter` to handle every case — no surface can "forget" a kind or
/// leave a spinner. Invalid states are unrepresentable: each case carries exactly
/// what its presenter needs.
public enum Outcome: Equatable {
    /// A readable article was obtained. Carries the extracted content + the winning
    /// source HTML (for cover-image extraction).
    case article(ArticleContent, html: String)
    /// A product page with a fetched price → price tracking.
    case product(ProductInfo, html: String)
    /// A social post (X / Bluesky / Reddit / Instagram). `itemID` may be nil for an
    /// opaque/short link that still classifies as the platform.
    case social(ContentPlatform, itemID: String?)
    /// A video. Never article-extracted.
    case video(ContentPlatform, itemID: String?)
    /// An imported document (pdf / epub / …).
    case document(type: String)
    /// A genuine paywall we couldn't read silently, parked under a title for the
    /// interactive archive-CAPTCHA reader.
    case needsArchive(title: String)
    /// A genuine failure (unreachable ordinary page) OR the overall-timeout fired —
    /// the surface shows an error, never an infinite spinner. Carries the coarse
    /// reason when one was captured (HTTP status / offline / timeout / nothing
    /// readable) so the failed card can explain itself; nil when unclassifiable.
    /// `case .failed` still matches without binding, so pattern-matching call
    /// sites are unaffected.
    case failed(SaveFailureReason?)
    /// The classifier demanded a kind whose processor ISN'T LINKED into this
    /// app (the compile-time surface split): an article/product URL saved in
    /// an app that doesn't handle that kind. Surfaces drop it with the
    /// generic unsupported-kind error (`SurfaceSupport`); the central Luna
    /// app registers every processor and never produces this.
    case unsupported(owner: LunaApp)

    public static func == (lhs: Outcome, rhs: Outcome) -> Bool {
        switch (lhs, rhs) {
        case let (.article(lc, lh), .article(rc, rh)):
            return lc.title == rc.title && lc.bodyTextLength == rc.bodyTextLength && lh == rh
        case let (.product(lp, lh), .product(rp, rh)): return lp == rp && lh == rh
        case let (.social(lp, lid), .social(rp, rid)): return lp == rp && lid == rid
        case let (.video(lp, lid), .video(rp, rid)): return lp == rp && lid == rid
        case let (.document(lt), .document(rt)): return lt == rt
        case let (.needsArchive(lt), .needsArchive(rt)): return lt == rt
        case let (.failed(l), .failed(r)): return l == r
        case let (.unsupported(lo), .unsupported(ro)): return lo == ro
        default: return false
        }
    }
}

/// The complete result of URL ingestion. `url` is the exact canonical URL that
/// was classified and processed, including any async wrapper resolution. Store
/// writers must use it instead of independently re-unwrapping the input.
public struct IngestResult: Equatable {
    public let url: URL
    public let outcome: Outcome

    public init(url: URL, outcome: Outcome) {
        self.url = url
        self.outcome = outcome
    }
}

/// THE single shared ingest pipeline every surface calls. It runs the WHOLE
/// decision identically for the main app, both share-sheet extensions, the app
/// intents, and incoming friend shares — so they can never diverge in WHAT they
/// decide; they differ only in how they present the `Outcome`.
///
/// Fixed order (same for every surface):
///   1. `URLUnwrapper.unwrap` ONCE — Facebook deep links, Apple/Google News,
///      shorteners — offline-first, tracking-stripped (every surface unwraps now).
///   2. `Classifier.classify` — deterministic `KnownSite` table first, then HTML
///      heuristics. Platform/video/audio recognition is the FIRST branch, so a
///      platform URL is decided before any fetch and can NEVER reach *HTML*
///      article extraction on any surface. (A social post may still become an
///      `.article` in step 3, but only through the platform's own text API — never
///      by scraping the platform's page.)
///   3. Per-kind processing — article→extract; paywalledArticle→bypass plan then
///      extract, else `.needsArchive`; product→`ProductMetadataExtractor`;
///      social→the social-text processor (a long-form X post / self-thread becomes
///      `.article`), else `PlatformRecognizer`; video/audio→`PlatformRecognizer`;
///      document→`.document`.
///
/// The whole call is wrapped in ONE mandatory overall timeout (`processTimeout`),
/// so it can NEVER hang — on timeout it returns `.failed` (or `.needsArchive` for a
/// hard-paywall host). Every production surface uses the same no-WebView processing
/// policy, keeping classification independent of the capture host.
///
/// Dependency-free of UIKit/CloudKit so it compiles in the extension targets. Never
/// writes the store — the surface persists from the `Outcome`. Tested by
/// `IngestPipelineTests` (parity across sources via a mock fetcher).
public enum IngestPipeline {

    /// The mandatory upper bound on a whole `process` call. Each inner stage is
    /// individually bounded too (the bypass silent chain ~20s, each fetch ~12–30s),
    /// but this is the hard ceiling that guarantees the call always resolves.
    public static let processTimeout: TimeInterval = 28

    /// Runs the complete pipeline for `input`, ALWAYS within `timeout`. On timeout
    /// returns `.needsArchive` for a hard-paywall host (the archive reader is its
    /// only route) and `.failed` otherwise — never an infinite wait.
    public static func process(
        _ input: IngestInput,
        timeout: TimeInterval = processTimeout,
        session: URLSession = .shared,
        fetcher: HTMLFetching = ArticleFetcher(),
        productDetector: ProductPageDetector = ProductPageDetector(),
        articleProcessor: ArticleIngestProcessing? = IngestKindProcessors.article,
        productProcessor: ProductIngestProcessing? = IngestKindProcessors.product,
        socialTextProcessor: SocialTextIngestProcessing? = IngestKindProcessors.socialText
    ) async -> Outcome {
        await processResolved(
            input, timeout: timeout, session: session, fetcher: fetcher,
            productDetector: productDetector, articleProcessor: articleProcessor,
            productProcessor: productProcessor, socialTextProcessor: socialTextProcessor).outcome
    }

    /// Runs the pipeline and returns both the outcome and the canonical URL it
    /// processed. This is the persistence-facing API used by every surface that
    /// needs to update/dedupe a stored item after an async unwrap.
    public static func processResolved(
        _ input: IngestInput,
        timeout: TimeInterval = processTimeout,
        session: URLSession = .shared,
        fetcher: HTMLFetching = ArticleFetcher(),
        productDetector: ProductPageDetector = ProductPageDetector(),
        articleProcessor: ArticleIngestProcessing? = IngestKindProcessors.article,
        productProcessor: ProductIngestProcessing? = IngestKindProcessors.product,
        socialTextProcessor: SocialTextIngestProcessing? = IngestKindProcessors.socialText
    ) async -> IngestResult {
        await withTaskGroup(of: IngestResult?.self) { group in
            group.addTask {
                await runUnbounded(
                    input, session: session, fetcher: fetcher,
                    productDetector: productDetector, articleProcessor: articleProcessor,
                    productProcessor: productProcessor, socialTextProcessor: socialTextProcessor)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                // The timeout leg returns the hard-fail fallback for `input.url` — a
                // hard-paywall host parks for the archive reader, everything else fails.
                let url = URLUnwrapper.unwrapOffline(input.url).url
                let outcome = ArticleFetcher.isHardPaywallHost(url)
                    ? Outcome.needsArchive(title: ArticleFetcher.articleTitleGuess(from: url))
                    : .failed(.timedOut)
                return IngestResult(url: url, outcome: outcome)
            }
            let first = await group.next() ?? IngestResult(url: input.url, outcome: .failed(.timedOut))
            group.cancelAll()
            return first ?? IngestResult(url: input.url, outcome: .failed(.timedOut))
        }
    }

    /// The pipeline body, WITHOUT the overall timeout (which `process` wraps). Split
    /// out so the timeout is the single guard at the top and the stages stay linear.
    private static func runUnbounded(
        _ input: IngestInput,
        session: URLSession,
        fetcher: HTMLFetching,
        productDetector: ProductPageDetector,
        articleProcessor: ArticleIngestProcessing?,
        productProcessor: ProductIngestProcessing?,
        socialTextProcessor: SocialTextIngestProcessing?
    ) async -> IngestResult {
        // (1) Unwrap ONCE — every surface gets the same offline-first, tracking-
        // stripped unwrap (Facebook deep links, Apple/Google News, shorteners).
        let unwrapped = await URLUnwrapper.unwrap(input.url, session: session)
        let url = unwrapped.url

        // (2) Classify deterministically (URL-only). Platform/video/document are
        // decided here, before any fetch, so they can never reach HTML article
        // extraction. A social post gets one further question asked of it in (2b).
        let kind = Classifier.classify(url: url, documentType: input.documentType)
        switch kind {
        case .document(let type):
            return IngestResult(url: url, outcome: .document(type: type))
        case let .video(platform, itemID):
            return IngestResult(url: url, outcome: .video(platform, itemID: itemID))
        case let .social(platform, itemID):
            // (2b) A social post is the one kind whose routing can't be settled from
            // the URL: the link says "an X post", not whether the post holds a quip
            // or an essay. Offer it to the social-text processor, which answers by
            // reading the post; a long-form post (an X Article, a long single post,
            // or the poster's own chained thread) becomes a real reader article,
            // and everything else declines and stays `.social` exactly as before.
            //
            // Only article-handling apps register a processor, so the Downloader and
            // Price Tracker take the unchanged path without linking any of this.
            if let socialTextProcessor,
               let read = await socialTextProcessor.article(
                    platform: platform, itemID: itemID, url: url) {
                return IngestResult(url: url, outcome: .article(read.content, html: read.html))
            }
            return IngestResult(url: url, outcome: .social(platform, itemID: itemID))
        case .product, .article, .paywalledArticle, .undetermined:
            // Web processing: only NOW do we fetch HTML, (re)classify with the HTML
            // for the undetermined/product confirmation, fetch price, resolve the
            // article, run the bypass plan.
            return IngestResult(url: url, outcome: await processWeb(
                url: url, classifiedKind: kind, input: input, fetcher: fetcher,
                productDetector: productDetector, articleProcessor: articleProcessor,
                productProcessor: productProcessor))
        }
    }

    /// The web-processing branch for an article/product/paywalled/undetermined URL.
    /// Product handling runs first only for a known shop or an otherwise-undetermined
    /// page (a product is never paywall-bypassed). A deterministic article/news
    /// classification is authoritative: publisher pages often embed store cards,
    /// subscription offers, and retail component state that look product-like but do
    /// not change the primary page into a product. Everything else is resolved through
    /// the gated article bypass strategies and mapped to `.article` / `.needsArchive`
    /// / `.failed`.
    private static func processWeb(
        url: URL,
        classifiedKind: ContentKind,
        input: IngestInput,
        fetcher: HTMLFetching,
        productDetector: ProductPageDetector,
        articleProcessor: ArticleIngestProcessing?,
        productProcessor: ProductIngestProcessing?
    ) async -> Outcome {
        // (2c) A search-results URL is decided BEFORE the fetch: there is no single
        // item on it for any kind to own, so a direct share fails immediately
        // instead of spending a round-trip (and, for a shop host, a price scrape)
        // discovering it. `forceArticle` is the user overriding us on purpose.
        if !input.forceArticle, isMultiItemListingURL(url, classifiedKind: classifiedKind) {
            return .failed(.notContent)
        }

        // Fetch the direct HTML once (reusing the surface's prefetch) — shared by
        // product detection and article resolution so we never double-fetch.
        let directHTML: String?
        if let prefetched = input.prefetchedHTML {
            directHTML = prefetched
        } else if input.forceArticle {
            directHTML = nil
        } else {
            directHTML = try? await fetcher.fetchHTML(from: url)
        }

        // (3a) Product handling — a product page becomes a tracker and is NEVER
        // paywall-bypassed. `forceArticle` skips this entirely. A deterministic
        // `.product(.knownShopHost)` from the classifier is TRUSTED — we go straight
        // to extraction (no redundant `ProductPageDetector.detect` gate, which would
        // otherwise miss host-specific price shapes the per-host `ProductPriceRule`
        // extractor knows, e.g. Target `current_retail` / Walmart `currentPrice`).
        // Heuristic product detection is limited to `.undetermined` pages. Known news
        // classifications remain articles even when a publisher embeds priced store
        // cards or subscription/product components (New Yorker and similar sites).
        let shouldExtractProduct: Bool
        switch classifiedKind {
        case .product:
            shouldExtractProduct = true
        case .undetermined:
            shouldExtractProduct = directHTML.map {
                productDetector.detect(urlString: url.absoluteString, html: $0) != nil
            } ?? false
        case .article, .paywalledArticle, .social, .video, .document:
            shouldExtractProduct = false
        }
        if !input.forceArticle, shouldExtractProduct {
            // The classification decided this page is a product for EVERY app
            // (shared detector); whether it can be PROCESSED depends on the
            // linked product processor. Without one, the save is dropped as
            // Price-Tracker-owned — never silently re-read as an article.
            guard let productProcessor else { return .unsupported(owner: .priceTracker) }
            if let product = await productProcessor.extract(url: url, html: directHTML ?? "") {
                return .product(product, html: directHTML ?? "")
            }
            // No trustworthy price → fall through to the article path below
            // (matching the pre-split behavior; a product-handling app without
            // an article processor then reports the article kind unsupported).
        }

        // (3a½) An index / front / listing page has no single article on it. The
        // Safari extension has always applied this veto before offering its pill
        // (`content.js`'s `looksLikeNonArticleIndex`); without the Swift twin, an
        // index that happened to extract past the readable threshold became a real
        // `.article`, and one that didn't parked for the archive reader — which is
        // why pages Safari itself declined to offer filled the recents tray.
        //
        // A page showing paywall evidence is EXEMPT. A metered body cut back to
        // headline links is genuinely link-dense, and a hard-paywall host serves a
        // stub with nothing but navigation on it; vetoing those would disable the
        // unlock the Reader exists for. That is the whole difference between "we
        // can't read this yet" and "there is nothing here to read".
        if !input.forceArticle, !input.trustsPrefetchedHTML,
           !ArticleFetcher.isHardPaywallHost(url),
           !(directHTML.map(declaresPaywall) ?? false),
           ListingPage.isNonContentPage(url: url, html: directHTML) {
            return .failed(.notContent)
        }

        // (3b) Resolve the article: direct fetch (reusing `directHTML`), then the
        // silent bypass strategies the gate allows — article-kind processing,
        // present only in article-handling apps.
        guard let articleProcessor else { return .unsupported(owner: .reader) }
        return await articleProcessor.process(
            url: url, directHTML: directHTML,
            trustsPrefetchedHTML: input.trustsPrefetchedHTML, fetcher: fetcher)
    }

    /// A URL that names a set of items rather than one — a search-results page on
    /// any site, plus (for a page the shop table already claimed) a commerce
    /// search / browse / category grid.
    ///
    /// The commerce half is scoped to a product classification on purpose:
    /// `ProductPageDetector.urlIsMultiProductListing` treats a leading `s` segment
    /// as a search, which is right for `amazon.com/s?k=…` and wrong for
    /// `medium.com/s/<publication>`. It matters here because a deterministic
    /// `.product(.knownShopHost)` SKIPS `ProductPageDetector.detect`, so an Amazon
    /// search URL used to reach price extraction, find no price, and fall through
    /// to the article path.
    private static func isMultiItemListingURL(
        _ url: URL, classifiedKind: ContentKind
    ) -> Bool {
        if ListingPage.isSearchResultsURL(url) { return true }
        guard case .product = classifiedKind else { return false }
        return ProductPageDetector.urlIsMultiProductListing(url)
    }

    /// Whether the page itself says it is locked — a publisher lock declaration or
    /// a gate marker in the raw markup. The same two signals `BypassGate` treats as
    /// paywall evidence, checked here without depending on the bypass module.
    private static func declaresPaywall(_ html: String) -> Bool {
        if PaywallDetector.htmlDeclaresLocked(html) { return true }
        let lowered = html.lowercased()
        return PaywallDetector.gateMarkers.contains { lowered.contains($0) }
    }
}

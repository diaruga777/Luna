//
//  IngestPipeline.swift
//  ReaderKit
//

import LunaPaywallBypass
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
    /// the surface shows an error, never an infinite spinner.
    case failed

    public static func == (lhs: Outcome, rhs: Outcome) -> Bool {
        switch (lhs, rhs) {
        case let (.article(lc, lh), .article(rc, rh)):
            return lc.title == rc.title && lc.bodyTextLength == rc.bodyTextLength && lh == rh
        case let (.product(lp, lh), .product(rp, rh)): return lp == rp && lh == rh
        case let (.social(lp, lid), .social(rp, rid)): return lp == rp && lid == rid
        case let (.video(lp, lid), .video(rp, rid)): return lp == rp && lid == rid
        case let (.document(lt), .document(rt)): return lt == rt
        case let (.needsArchive(lt), .needsArchive(rt)): return lt == rt
        case (.failed, .failed): return true
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
///      platform URL is decided before any fetch and can NEVER reach article
///      extraction on any surface.
///   3. Per-kind processing — article→extract; paywalledArticle→bypass plan then
///      extract, else `.needsArchive`; product→`ProductMetadataExtractor`;
///      social/video/audio→`PlatformRecognizer`; document→`.document`.
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
    ///
    /// - `render`: an optional rendered-HTML test seam for JS-only product prices.
    ///   Production callers leave it nil so every capture surface processes equally.
    public static func process(
        _ input: IngestInput,
        timeout: TimeInterval = processTimeout,
        session: URLSession = .shared,
        fetcher: HTMLFetching = ArticleFetcher(),
        extractor: ArticleExtractor = ArticleExtractor(),
        productDetector: ProductPageDetector = ProductPageDetector(),
        metadataExtractor: ProductMetadataExtractor = ProductMetadataExtractor(),
        render: ((URL) async -> String?)? = nil,
        runner: BypassRunning? = nil,
        replayLog: ((EventKind) async -> Void)? = nil
    ) async -> Outcome {
        await processResolved(
            input, timeout: timeout, session: session, fetcher: fetcher,
            extractor: extractor, productDetector: productDetector,
            metadataExtractor: metadataExtractor, render: render, runner: runner,
            replayLog: replayLog).outcome
    }

    /// Runs the pipeline and returns both the outcome and the canonical URL it
    /// processed. This is the persistence-facing API used by every surface that
    /// needs to update/dedupe a stored item after an async unwrap.
    public static func processResolved(
        _ input: IngestInput,
        timeout: TimeInterval = processTimeout,
        session: URLSession = .shared,
        fetcher: HTMLFetching = ArticleFetcher(),
        extractor: ArticleExtractor = ArticleExtractor(),
        productDetector: ProductPageDetector = ProductPageDetector(),
        metadataExtractor: ProductMetadataExtractor = ProductMetadataExtractor(),
        render: ((URL) async -> String?)? = nil,
        runner: BypassRunning? = nil,
        replayLog: ((EventKind) async -> Void)? = nil
    ) async -> IngestResult {
        await withTaskGroup(of: IngestResult?.self) { group in
            group.addTask {
                await runUnbounded(
                    input, session: session, fetcher: fetcher, extractor: extractor,
                    productDetector: productDetector, metadataExtractor: metadataExtractor,
                    render: render, runner: runner, replayLog: replayLog)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                // The timeout leg returns the hard-fail fallback for `input.url` — a
                // hard-paywall host parks for the archive reader, everything else fails.
                let url = URLUnwrapper.unwrapOffline(input.url).url
                let outcome = ArticleFetcher.isHardPaywallHost(url)
                    ? Outcome.needsArchive(title: ArticleFetcher.articleTitleGuess(from: url))
                    : .failed
                return IngestResult(url: url, outcome: outcome)
            }
            let first = await group.next() ?? IngestResult(url: input.url, outcome: .failed)
            group.cancelAll()
            return first ?? IngestResult(url: input.url, outcome: .failed)
        }
    }

    /// The pipeline body, WITHOUT the overall timeout (which `process` wraps). Split
    /// out so the timeout is the single guard at the top and the stages stay linear.
    private static func runUnbounded(
        _ input: IngestInput,
        session: URLSession,
        fetcher: HTMLFetching,
        extractor: ArticleExtractor,
        productDetector: ProductPageDetector,
        metadataExtractor: ProductMetadataExtractor,
        render: ((URL) async -> String?)?,
        runner: BypassRunning?,
        replayLog: ((EventKind) async -> Void)?
    ) async -> IngestResult {
        // (1) Unwrap ONCE — every surface gets the same offline-first, tracking-
        // stripped unwrap (Facebook deep links, Apple/Google News, shorteners).
        let unwrapped = await URLUnwrapper.unwrap(input.url, session: session)
        let url = unwrapped.url
        if unwrapped.didUnwrap {
            await replayLog?(.unwrap(
                fromURLString: input.url.absoluteString, toURLString: url.absoluteString))
        }

        // (2) Classify deterministically (URL-only). Platform/video/document
        // are decided here, before any fetch, so they can never reach article extraction.
        let kind = Classifier.classify(url: url, documentType: input.documentType)
        switch kind {
        case .document(let type):
            return IngestResult(url: url, outcome: .document(type: type))
        case let .video(platform, itemID):
            return IngestResult(url: url, outcome: .video(platform, itemID: itemID))
        case let .social(platform, itemID):
            return IngestResult(url: url, outcome: .social(platform, itemID: itemID))
        case .product, .article, .paywalledArticle, .undetermined:
            // Web processing: only NOW do we fetch HTML, (re)classify with the HTML
            // for the undetermined/product confirmation, fetch price, resolve the
            // article, run the bypass plan.
            return IngestResult(url: url, outcome: await processWeb(
                url: url, classifiedKind: kind, input: input, fetcher: fetcher, extractor: extractor,
                productDetector: productDetector, metadataExtractor: metadataExtractor,
                render: render, runner: runner, replayLog: replayLog))
        }
    }

    /// The web-processing branch for an article/product/paywalled/undetermined URL.
    /// Product handling runs first (a product is never paywall-bypassed); otherwise
    /// the article is resolved through the gated silent bypass strategies and mapped
    /// to `.article` / `.needsArchive` / `.failed`.
    private static func processWeb(
        url: URL,
        classifiedKind: ContentKind,
        input: IngestInput,
        fetcher: HTMLFetching,
        extractor: ArticleExtractor,
        productDetector: ProductPageDetector,
        metadataExtractor: ProductMetadataExtractor,
        render: ((URL) async -> String?)?,
        runner: BypassRunning?,
        replayLog: ((EventKind) async -> Void)?
    ) async -> Outcome {
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
        // Only an undetermined/article-classified page needs the heuristic detector to
        // confirm it's really a product before extracting.
        let classifiedAsProduct: Bool = { if case .product = classifiedKind { return true }; return false }()
        if !input.forceArticle, let html = directHTML,
           let metadata = await metadataExtractor.extract(url: url, html: html, render: render),
           classifiedAsProduct || !metadata.sellers.isEmpty
                || productDetector.detect(urlString: url.absoluteString, html: html) != nil {
            let product = ProductInfo(
                name: metadata.name, priceAmount: metadata.price.amount,
                priceCurrency: metadata.price.currency, imageURL: metadata.imageURL,
                brand: metadata.brand, productID: metadata.productID,
                sellers: metadata.sellers)
            return .product(product, html: html)
        }

        // (3b) Resolve the article: direct fetch (reusing `directHTML`), then the
        // silent bypass strategies the gate allows.
        let resolution = await ArticleResolver.resolve(
            url: url, prefetchedHTML: directHTML, fetcher: fetcher,
            extractor: extractor, runner: runner, replayLog: replayLog,
            trustsPrefetchedHTML: input.trustsPrefetchedHTML)

        switch resolution {
        case let .readable(content, html):
            return .article(content, html: html)
        case let .paywalled(title):
            return .needsArchive(title: title)
        case .unreadable:
            // A browser-only site rule means the background fetch is not the final
            // authority. Anti-bot front doors such as Reuters/DataDome can reject
            // URLSession before yielding even a title, while the rule's direct-unlock
            // WKWebView leg (the same script-blocking path used by the Safari extension)
            // can still render the article. Preserve that route instead of marking the
            // item failed before the browser tier gets a chance to run.
            let hasBrowserRecovery = !BypassPlan.make(
                for: url, directHTML: directHTML
            ).webPreStages.isEmpty
            // A hard-paywall host or already-archived URL is likewise still readable
            // behind a user-solved CAPTCHA. Only a truly unreachable ordinary page
            // with no eligible browser recovery is a genuine failure.
            if hasBrowserRecovery || ArticleFetcher.isHardPaywallHost(url)
                || ArticleFetcher.isArchiveTodayURL(url) {
                return .needsArchive(title: ArticleFetcher.articleTitleGuess(from: url))
            }
            return .failed
        }
    }
}

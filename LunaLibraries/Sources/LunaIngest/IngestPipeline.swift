//
//  IngestPipeline.swift
//  ReaderKit
//

import LunaFetch
import LunaHTMLClassification
import LunaURLClassification
import LunaModels
import Foundation

/// Everything a surface knows about an incoming save, handed to the one
/// shared pipeline. The `source` travels with the input so per-surface
/// presentation policy (interactive price UI vs. silent save) is data, not
/// branching scattered across view controllers. The pipeline unwraps and
/// classifies the URL identically for every source; only presentation
/// differs afterward.
public struct IngestInput {
    /// The incoming URL, exactly as the surface received it. It may still be
    /// an `fbrpc://` deep link or a news-aggregator wrapper — the pipeline
    /// unwraps it once, up front, so every surface gets the same unwrap.
    public let url: URL
    /// Where the save came from. Drives presentation policy, never the decision.
    public let source: CaptureSource
    /// A save-time document type flag (pdf/epub/…) when the surface imported
    /// a file rather than a web URL. Always wins classification (`.document`).
    public let documentType: String?
    /// Page HTML the surface already has, reused so the pipeline does not
    /// refetch it.
    public let page: CapturedPage
    /// The "Read instead" override. Forces the article path even for a
    /// product page.
    public let forceArticle: Bool
    /// What the user asked for beyond a plain save. Travels to every plugin
    /// hook as `intent`; nil is the ordinary save.
    public let intent: IngestIntent?

    public init(
        url: URL,
        source: CaptureSource,
        documentType: String? = nil,
        page: CapturedPage = .none,
        forceArticle: Bool = false,
        intent: IngestIntent? = nil
    ) {
        self.url = url
        self.source = source
        self.documentType = documentType
        self.page = page
        self.forceArticle = forceArticle
        self.intent = intent
    }
}

/// A user's explicit ask for a save, beyond storing the link
/// (`claudedocs/plans/transcription-plugins.md` decision 4).
public enum IngestIntent: String, Equatable, Sendable {
    /// Transcribe the recording behind the URL into a reader article. The media
    /// plugins decline it; a transcript plugin claims it; a walk nobody serves
    /// ends in `.failed(.noTranscriptSource)` rather than a download.
    case transcribe
}

/// The single unified result every surface receives from `IngestPipeline.process`.
/// It is exhaustive over every kind a save can become, so the compiler forces
/// each `OutcomePresenter` to handle every case: no surface can forget a kind
/// or leave a spinner. Invalid states are unrepresentable, since each case
/// carries exactly what its presenter needs.
public enum Outcome: Equatable {
    /// A readable article was obtained. Carries the extracted content and the
    /// winning source HTML, for cover-image extraction.
    case article(ArticleContent, html: String)
    /// A product page with a fetched price. Routes to price tracking.
    case product(ProductInfo, html: String)
    /// A social post (X, Bluesky, Reddit, Instagram). `itemID` may be nil for
    /// an opaque or short link that still classifies as the platform.
    case social(ContentPlatform, itemID: String?)
    /// A video. Never article-extracted.
    case video(ContentPlatform, itemID: String?)
    /// An imported document (pdf, epub, …).
    case document(type: String)
    /// A genuine paywall that could not be read silently, parked under a
    /// title for the interactive archive-CAPTCHA reader.
    case needsArchive(title: String)
    /// A genuine failure (an unreachable ordinary page) or the overall
    /// timeout firing. The surface shows an error, never an infinite spinner.
    /// Carries the coarse reason when one was captured (HTTP status, offline,
    /// timeout, nothing readable) so the failed card can explain itself; nil
    /// when unclassifiable. `case .failed` still matches without binding, so
    /// existing pattern-matching call sites are unaffected by the associated
    /// value.
    case failed(SaveFailureReason?)
    /// The classifier chose a kind whose processor is not linked into this
    /// app: an article or product URL saved in an app that does not handle
    /// that kind. Surfaces drop it with the generic unsupported-kind error
    /// (`SurfaceSupport`); the central Luna app registers every processor and
    /// never produces this case.
    case unsupported(owner: LunaApp)
    /// A plugin asked for a browser the running process cannot present, so the
    /// save is parked in the `.needsCaptcha` lock and finished in the app.
    /// Carries the owning plugin, which is what routes the resume back to it.
    /// Only the central Luna app can produce this — the sibling apps install no
    /// plugin stage (`claudedocs/plans/plugin-platform.md` §8).
    case locked(pluginID: String)
    /// A plugin handed over a recording to transcribe. The save is parked
    /// `.pending` under its title with a job row, and the central app's runner
    /// downloads, transcribes and persists the article later
    /// (`claudedocs/plans/transcription-plugins.md` §3.4).
    case transcription(TranscriptionRequest)

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
        case let (.locked(lp), .locked(rp)): return lp == rp
        case let (.transcription(lr), .transcription(rr)): return lr == rr
        default: return false
        }
    }
}

/// The complete result of URL ingestion. `url` is the exact canonical URL that
/// was classified and processed, including any async wrapper resolution. A
/// store writer must use it instead of independently re-unwrapping the input.
public struct IngestResult: Equatable {
    public let url: URL
    public let outcome: Outcome
    /// The plugin that produced `outcome`, when one did. A store writer stamps
    /// it onto the save (`saves.plugin_id`), which is what routes a later
    /// price refresh or asset re-resolution back to the same plugin.
    public let pluginID: String?

    public init(url: URL, outcome: Outcome, pluginID: String? = nil) {
        self.url = url
        self.outcome = outcome
        self.pluginID = pluginID
    }
}

/// The single shared ingest pipeline every surface calls. It runs the whole
/// decision identically for the main app, both share-sheet extensions, the
/// app intents, and incoming friend shares, so they can never diverge in what
/// they decide. They differ only in how they present the `Outcome`.
///
/// Fixed order, the same for every surface:
///   1. `URLUnwrapper.unwrap` once — Facebook deep links, Apple/Google News,
///      shorteners — offline-first and tracking-stripped.
///   2. `Classifier.classify`: the deterministic `KnownSite` table first, then
///      HTML heuristics. Platform, video, and audio recognition is the first
///      branch, so a platform URL is decided before any fetch and can never
///      reach HTML article extraction on any surface. (A social post may
///      still become an `.article` in step 3, but only through the
///      platform's own text API, never by scraping the platform's page.)
///   3. Per-kind processing: article extracts; paywalledArticle runs the
///      bypass plan then extracts, else returns `.needsArchive`; product goes
///      to `ProductMetadataExtractor`; social goes to the social-text
///      processor (a long-form X post or self-thread becomes `.article`),
///      else `PlatformRecognizer`; video/audio go to `PlatformRecognizer`;
///      document becomes `.document`.
///
/// One mandatory idle timeout (`processTimeout`) wraps the whole call, so it
/// can never hang: on timeout it returns `.failed`, or `.needsArchive` for a
/// hard-paywall host. Network progress resets that deadline, so a slow but
/// healthy byte stream is not cut off. Every production surface uses the same
/// no-WebView processing policy, keeping classification independent of the
/// capture host.
///
/// The pipeline has no dependency on UIKit or CloudKit, so it compiles in the
/// extension targets. It never writes the store; the surface persists from
/// the `Outcome`. `IngestPipelineTests` checks parity across sources via a
/// mock fetcher.
public enum IngestPipeline {

    /// The mandatory maximum silence during a `process` call. Each inner stage
    /// is individually bounded too (the bypass silent chain to about 20s,
    /// each fetch to about 12–30s). Useful progress resets this watchdog.
    public static let processTimeout: TimeInterval = 30

    /// Runs the complete pipeline for `input`, allowing at most `timeout`
    /// seconds without progress. On timeout, returns `.needsArchive` for a
    /// hard-paywall host (the archive reader is its only route) and `.failed`
    /// otherwise. Never waits forever.
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
    /// processed. This is the persistence-facing API used by every surface
    /// that needs to update or dedupe a stored item after an async unwrap.
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
        let limitedResult = await IdleTimeLimit.run(timeout) {
            await runUnbounded(
                input, session: session, fetcher: fetcher,
                productDetector: productDetector, articleProcessor: articleProcessor,
                productProcessor: productProcessor, socialTextProcessor: socialTextProcessor)
        }
        if let result = limitedResult {
            return result
        }

        // The idle deadline returns independently of an uncooperative losing
        // task. A structured task-group race cannot make that guarantee because
        // its scope drains every child before returning.
        let url = URLUnwrapper.unwrapOffline(input.url).url
        let outcome = ArticleFetcher.isHardPaywallHost(url)
            ? Outcome.needsArchive(title: ArticleFetcher.articleTitleGuess(from: url))
            : .failed(.timedOut)
        SaveDiagnostics.record(
            "pipeline: idle budget of \(Int(timeout))s elapsed — "
                + (ArticleFetcher.isHardPaywallHost(url)
                    ? "hard-paywall host, parking for archive" : "failing timedOut"),
            category: "ingest")
        return IngestResult(url: url, outcome: outcome)
    }

    /// The pipeline body, without the overall timeout that `process` wraps
    /// around it. Split out so the timeout is the single guard at the top and
    /// the stages stay linear.
    private static func runUnbounded(
        _ input: IngestInput,
        session: URLSession,
        fetcher: HTMLFetching,
        productDetector: ProductPageDetector,
        articleProcessor: ArticleIngestProcessing?,
        productProcessor: ProductIngestProcessing?,
        socialTextProcessor: SocialTextIngestProcessing?
    ) async -> IngestResult {
        // (1) Unwrap once. Every surface gets the same offline-first,
        // tracking-stripped unwrap (Facebook deep links, Apple/Google News,
        // shorteners).
        let unwrapped = await URLUnwrapper.unwrap(input.url, session: session)
        let url = unwrapped.url
        if unwrapped.didUnwrap {
            SaveDiagnostics.record(
                "pipeline: unwrapped → \(SaveDiagnostics.url(url))", category: "ingest")
        }

        // (1b) Plugins run before the Swift classifier and may claim a host
        // Swift already knows. A plugin that declines, breaks or times out
        // falls through to the classifier below, so the Swift path is the
        // floor under every plugin. Nil in the three sibling apps, which link
        // no plugin platform.
        if let pluginStage = pluginStage {
            switch await pluginStage.run(
                IngestInput(
                    url: url, source: input.source, documentType: input.documentType,
                    page: input.page, forceArticle: input.forceArticle, intent: input.intent),
                fetcher: fetcher)
            {
            case .passed:
                // A transcribe request only a plugin can serve. The Swift
                // classifier would turn it into a download, which is the one
                // outcome the user did not ask for.
                if input.intent == .transcribe {
                    SaveDiagnostics.record(
                        "pipeline: transcribe intent, every plugin passed — failing noTranscriptSource",
                        category: "plugin")
                    return IngestResult(url: url, outcome: .failed(.noTranscriptSource))
                }
            case let .outcome(outcome, pluginID):
                return IngestResult(url: url, outcome: outcome, pluginID: pluginID)
            case let .locked(pluginID):
                return IngestResult(
                    url: url, outcome: .locked(pluginID: pluginID), pluginID: pluginID)
            }
        }

        // (2) Classify deterministically, from the URL only. Platform, video,
        // and document are decided here, before any fetch, so they can never
        // reach HTML article extraction. A social post gets one further
        // question asked of it in (2b).
        let kind = Classifier.classify(url: url, documentType: input.documentType)
        SaveDiagnostics.record("pipeline: classified \(kind)", category: "ingest")
        switch kind {
        case .document(let type):
            return IngestResult(url: url, outcome: .document(type: type))
        case let .video(platform, itemID):
            return IngestResult(url: url, outcome: .video(platform, itemID: itemID))
        case let .social(platform, itemID):
            // (2b) A social post is the one kind whose routing cannot be
            // settled from the URL: the link says "an X post", not whether
            // the post holds a quip or an essay. Offer it to the social-text
            // processor, which answers by reading the post. A long-form post
            // (an X Article, a long single post, or the poster's own chained
            // thread) becomes a real reader article; everything else
            // declines and stays `.social`.
            //
            // Only article-handling apps register a processor, so the
            // Downloader and Price Tracker skip this step without linking
            // any of this code.
            if let socialTextProcessor,
               let read = await socialTextProcessor.article(
                    platform: platform, itemID: itemID, url: url) {
                SaveDiagnostics.record(
                    "pipeline: social post read as long-form article, "
                        + "\(read.content.bodyTextLength)ch", category: "ingest")
                return IngestResult(url: url, outcome: .article(read.content, html: read.html))
            }
            return IngestResult(url: url, outcome: .social(platform, itemID: itemID))
        case .product, .article, .paywalledArticle, .undetermined:
            // Web processing: only now do we fetch HTML, (re)classify with
            // the HTML for the undetermined/product confirmation, fetch
            // price, resolve the article, run the bypass plan.
            return IngestResult(url: url, outcome: await processWeb(
                url: url, classifiedKind: kind, input: input, fetcher: fetcher,
                productDetector: productDetector, articleProcessor: articleProcessor,
                productProcessor: productProcessor))
        }
    }

    /// The web-processing branch for an article, product, paywalled, or
    /// undetermined URL. Product handling runs first only for a known shop or
    /// an otherwise-undetermined page; a product is never paywall-bypassed. A
    /// deterministic article/news classification is authoritative: publisher
    /// pages often embed store cards, subscription offers, and retail
    /// component state that look product-like but do not turn the primary
    /// page into a product. Everything else resolves through the gated
    /// article bypass strategies and maps to `.article`, `.needsArchive`, or
    /// `.failed`.
    private static func processWeb(
        url: URL,
        classifiedKind: ContentKind,
        input: IngestInput,
        fetcher: HTMLFetching,
        productDetector: ProductPageDetector,
        articleProcessor: ArticleIngestProcessing?,
        productProcessor: ProductIngestProcessing?
    ) async -> Outcome {
        // (2c) A search-results URL is decided before the fetch: there is no
        // single item on it for any kind to own, so a direct share fails
        // immediately instead of spending a round trip (and, for a shop
        // host, a price scrape) discovering that. `forceArticle` is the user
        // deliberately overriding this veto.
        if !input.forceArticle, isMultiItemListingURL(url, classifiedKind: classifiedKind) {
            SaveDiagnostics.record(
                "pipeline: vetoed as a multi-item listing URL — no single item to save",
                category: "ingest")
            return .failed(.notContent)
        }

        // Fetch the direct HTML once, reusing the surface's prefetch if one
        // exists. Product detection and article resolution share this single
        // fetch, so the pipeline never fetches the page twice.
        let page: CapturedPage
        switch input.page {
        case .fetched, .unlockedCapture:
            page = input.page
        case .none where input.forceArticle:
            page = .none
        case .none:
            page = (try? await fetcher.fetchHTML(from: url)).map { .fetched($0) } ?? .none
        }
        let directHTML = page.html
        SaveDiagnostics.record(
            "pipeline: direct HTML "
                + (directHTML.map { "\($0.count)ch" } ?? "unavailable")
                + (input.page.html != nil ? " (prefetched by the surface)" : "")
                + (input.forceArticle ? " (forceArticle: skipped)" : ""),
            category: "ingest")

        // (3a) Product handling: a product page becomes a tracker and is
        // never paywall-bypassed. `forceArticle` skips this entirely. The
        // pipeline trusts a deterministic `.product(.knownShopHost)` from the
        // classifier and goes straight to extraction, skipping the
        // `ProductPageDetector.detect` gate. That gate would otherwise miss
        // host-specific price shapes the per-host `ProductPriceRule`
        // extractor knows, such as Target's `current_retail` or Walmart's
        // `currentPrice`. Heuristic product detection is limited to
        // `.undetermined` pages: a known news classification stays an
        // article even when the publisher embeds priced store cards or
        // subscription/product components (the New Yorker and similar sites
        // do this).
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
            // The shared detector decided this page is a product for every
            // app. Whether it can be processed depends on the linked product
            // processor. Without one, the save is dropped as
            // Price-Tracker-owned; it is never silently re-read as an article.
            SaveDiagnostics.record(
                "pipeline: product path entered (\(classifiedKind))", category: "price")
            guard let productProcessor else {
                SaveDiagnostics.record(
                    "pipeline: no product processor linked — Price-Tracker-owned",
                    category: "price")
                return .unsupported(owner: .priceTracker)
            }
            if let product = await productProcessor.extract(url: url, html: directHTML ?? "") {
                SaveDiagnostics.record(
                    "pipeline: product extracted — \(product.priceAmount) "
                        + "\(product.priceCurrency), \(product.sellers.count) seller(s)",
                    category: "price")
                return .product(product, html: directHTML ?? "")
            }
            SaveDiagnostics.record(
                "pipeline: no trustworthy price — falling through to the article path",
                category: "price")
            // No trustworthy price: fall through to the article path below.
            // A product-handling app without an article processor then
            // reports the article kind unsupported.
        }

        // (3a½) An index/front/listing page has no single article on it. The
        // Safari extension applies this same veto before offering its pill
        // (`content.js`'s `looksLikeNonArticleIndex`). This Swift twin keeps
        // the two in sync: without it, an index page that happened to
        // extract past the readable threshold would become a real
        // `.article`, filling the recents tray with pages Safari itself
        // declined to offer.
        //
        // A page showing paywall evidence is exempt from this veto. A
        // metered body cut back to headline links is genuinely link-dense,
        // and a hard-paywall host serves a stub with nothing but navigation
        // on it; vetoing those would disable the unlock the Reader exists
        // for. That is the whole difference between "we can't read this yet"
        // and "there is nothing here to read".
        if !input.forceArticle, !input.page.isUnlockedCapture,
           !ArticleFetcher.isHardPaywallHost(url),
           !(directHTML.map(declaresPaywall) ?? false),
           ListingPage.isNonContentPage(url: url, html: directHTML) {
            SaveDiagnostics.record(
                "pipeline: vetoed as an index/front/listing page — nothing here to read",
                category: "ingest")
            return .failed(.notContent)
        }

        // (3b) Resolve the article: the direct fetch (reusing `directHTML`),
        // then the silent bypass strategies the gate allows. This
        // article-kind processing is present only in article-handling apps.
        guard let articleProcessor else {
            SaveDiagnostics.record(
                "pipeline: no article processor linked — Reader-owned", category: "ingest")
            return .unsupported(owner: .reader)
        }
        SaveDiagnostics.record("pipeline: article path entered", category: "ingest")
        return await articleProcessor.process(url: url, page: page, fetcher: fetcher)
    }

    /// A URL that names a set of items rather than one: a search-results page
    /// on any site, plus, for a page the shop table already claimed, a
    /// commerce search/browse/category grid.
    ///
    /// The commerce half is scoped to a product classification on purpose.
    /// `ProductPageDetector.urlIsMultiProductListing` treats a leading `s`
    /// segment as a search, which is right for `amazon.com/s?k=…` and wrong
    /// for `medium.com/s/<publication>`. This scoping matters because a
    /// deterministic `.product(.knownShopHost)` skips
    /// `ProductPageDetector.detect`: without it, an Amazon search URL would
    /// reach price extraction, find no price, and fall through to the
    /// article path.
    private static func isMultiItemListingURL(
        _ url: URL, classifiedKind: ContentKind
    ) -> Bool {
        if ListingPage.isSearchResultsURL(url) { return true }
        guard case .product = classifiedKind else { return false }
        return ProductPageDetector.urlIsMultiProductListing(url)
    }

    /// Whether the page itself says it is locked: a publisher lock
    /// declaration or a gate marker in the raw markup. These are the same two
    /// signals `BypassGate` treats as paywall evidence, checked here without
    /// depending on the bypass module.
    private static func declaresPaywall(_ html: String) -> Bool {
        if PaywallDetector.htmlDeclaresLocked(html) { return true }
        let lowered = html.lowercased()
        return PaywallDetector.gateMarkers.contains { lowered.contains($0) }
    }
}

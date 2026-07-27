//
//  BypassGate.swift
//  ReaderKit
//

import LunaFetch
import LunaHTMLClassification
import LunaURLClassification
import LunaModels
import Foundation

/// The single hard GATE that decides whether a paywall bypass (any silent strategy
/// OR the WKWebView archive reader) may run for a page. It exists to stop bypass
/// false positives: a bypass must fire ONLY for content that is genuinely paywalled,
/// never for a fully-readable article, a product page, or a social/platform link.
///
/// Pure (no I/O, no UIKit) so it can be the one source of truth reused everywhere a
/// bypass could start — the resolver's silent strategies, the archive reader's
/// pre-stages, and both share-sheet extensions all consult it. Exercised via
/// `BypassScenarioTests` and transitively by every `BypassStrategySelector`/
/// `BypassPlan` test.
public enum BypassGate {

    /// Why a bypass was allowed (carrying the triggering signal) or blocked.
    public enum Decision: Equatable {
        /// A bypass MAY run. The associated `Signal` records which paywall evidence
        /// justified it (for diagnostics).
        case attempt(Signal)
        /// A bypass must NOT run. The associated `Block` records why.
        case block(Block)

        /// Convenience: whether a bypass is allowed.
        public var allowsBypass: Bool {
            if case .attempt = self { return true }
            return false
        }
    }

    /// The paywall evidence that justified a bypass attempt.
    public enum Signal: Equatable {
        /// A gate marker in the visible text (`PaywallDetector.gateMarkers`).
        case gateMarker
        /// The publisher's machine-readable lock declaration
        /// (`PaywallDetector.htmlDeclaresLocked`).
        case declaredLocked
        /// A known hard-paywall host (`ArticleFetcher.isHardPaywallHost`) whose body
        /// we couldn't read (or only got a teaser/stub for).
        case hardPaywallHostUnreadable
        /// An archive.today snapshot URL — always routed through the archive reader.
        case archiveSnapshot
        /// The direct fetch failed and the host is unknown, so we can't PROVE the
        /// page is free; a bypass is allowed as a best-effort recovery (this is the
        /// pre-existing behavior the resolver/selector already relied on).
        case unprovenFreeUnknownHost
    }

    /// Why a bypass was suppressed.
    public enum Block: Equatable {
        /// The page already has a readable, non-paywalled article body.
        case readableArticle
        /// A product page (`ProductPageDetector` positive) — routed to price
        /// tracking, never paywall-bypassed.
        case productPage
        /// A social-media / platform link (`PlatformRecognizer` positive, incl.
        /// platform links).
        case platformLink
        /// A short, non-article page with no paywall evidence (a JS shell / landing
        /// page that isn't actually walled).
        case notPaywalled
        /// A search-results / index / front page (`ListingPage`) — there is no
        /// single article behind it, so no strategy could unlock one and the
        /// archive.today CAPTCHA flow must never be offered for it.
        case nonContentPage
    }

    /// Whether a bypass may be attempted for `url`, given the direct page's `html`
    /// (nil if the direct fetch failed) and the already-extracted article
    /// (nil if extraction failed). PURE.
    ///
    /// Decision order — the BLOCKS come first so a genuine non-paywall can never be
    /// bypassed, then the paywall SIGNALS:
    /// 1. Platform/social link → block (these never paywall-bypass).
    /// 2. Product page → block (routed to price tracking), except that a
    ///    deterministic news-host classification is authoritative over commerce
    ///    furniture embedded in the publisher page.
    /// 2b. A search-results URL → block (nothing to unlock).
    /// 3. A readable, non-paywalled article body → block (already have the article).
    /// 4. A machine-readable lock declaration → attempt.
    /// 5. A gate marker in the page text → attempt.
    /// 6. A hard-paywall host with no readable body → attempt.
    /// 7. An archive.today snapshot URL → attempt.
    /// 8. Direct fetch failed on an unknown host → attempt (can't prove it's free).
    /// 9. Otherwise → block (not paywalled).
    public static func decision(for url: URL, html: String?, extracted: ArticleContent?) -> Decision {
        // (1) Platform/social links are
        // never paywall-bypassed; they render from a deep link, not extracted text.
        if PlatformRecognizer.recognize(url.absoluteString) != nil {
            return .block(.platformLink)
        }

        // (2) Product pages route to price tracking, never the bypass/archive flow.
        // Keep this in lockstep with IngestPipeline: deterministic news hosts remain
        // articles even when their page shell embeds store cards, subscription prices,
        // or generic retail component state. Otherwise this second gate can undo the
        // correct ingest classification and suppress the publisher's unlock plan.
        let deterministicKind = Classifier.classify(url: url)
        let heuristicsMayDecideProduct: Bool
        switch deterministicKind {
        case .product:
            return .block(.productPage)
        case .article, .paywalledArticle:
            heuristicsMayDecideProduct = false
        case .undetermined, .social, .video, .document:
            heuristicsMayDecideProduct = true
        }
        if heuristicsMayDecideProduct, let html,
           ProductPageDetector().detect(urlString: url.absoluteString, html: html) != nil {
            return .block(.productPage)
        }

        // (2b) A search-results URL has no single article behind it, so every
        // strategy below is pointless — and the last one is archive.today, which
        // would put a CAPTCHA in front of a Google search page.
        //
        // Deliberately the URL-ONLY half of `ListingPage`: the HTML listing shapes
        // (link density, repeated `<article>`s) describe a metered article whose
        // body has been cut back to headline links just as well as a real index, so
        // consulting them HERE would disable the unlock the Reader exists for. They
        // are applied one level up, in `IngestPipeline`, where a locked page is
        // exempt. Nothing is lost at the archive reader's own entry point either:
        // it builds its plan with `directHTML: nil`, so only this half could fire.
        if ListingPage.isSearchResultsURL(url) {
            return .block(.nonContentPage)
        }

        // (3) A fully-readable, non-paywalled article needs no bypass. Judged by the
        // shared `ArticleExtraction.isReadableArticle` predicate (HTML-aware: it folds
        // in the publisher-declared lock signal for a wall whose CTA text the extractor
        // stripped) — the single place the readable/locked decision lives.
        let htmlDeclaresLocked = html.map(PaywallDetector.htmlDeclaresLocked) ?? false
        if let extracted, ArticleExtraction.isReadableArticle(extracted, html: html) {
            return .block(.readableArticle)
        }

        // (4) Publisher-declared lock — the strongest paywall signal.
        if htmlDeclaresLocked {
            return .attempt(.declaredLocked)
        }

        // (5) A gate marker in the page text (cut-off body), at any length.
        if let html, htmlContainsGateMarker(html) {
            return .attempt(.gateMarker)
        }
        if let extracted, extracted.looksPaywalled {
            return .attempt(.gateMarker)
        }

        // (6) A known hard-paywall host whose body we couldn't read (no readable
        // extraction above) — the archive snapshot is the only way in.
        if ArticleFetcher.isHardPaywallHost(url) {
            return .attempt(.hardPaywallHostUnreadable)
        }

        // (7) An archive.today snapshot — always routed through the archive reader.
        if ArticleFetcher.isArchiveTodayURL(url) {
            return .attempt(.archiveSnapshot)
        }

        // (8) Direct fetch failed on an unknown host: we can't prove the page is free
        // (it may be JS-walled), so a best-effort bypass is allowed. A page we DID
        // fetch and that shows no paywall evidence falls through to (9).
        if html == nil {
            return .attempt(.unprovenFreeUnknownHost)
        }

        // (9) We have the HTML, it's not a product/platform page, shows no paywall
        // evidence, and isn't a hard-paywall host — it's simply not a wall.
        return .block(.notPaywalled)
    }

    /// Whether the HTML's visible text carries a high-precision gate marker (the
    /// same list `PaywallDetector` uses for extracted text). Cheap substring scan.
    private static func htmlContainsGateMarker(_ html: String) -> Bool {
        let lowered = html.lowercased()
        return PaywallDetector.gateMarkers.contains { lowered.contains($0) }
    }
}

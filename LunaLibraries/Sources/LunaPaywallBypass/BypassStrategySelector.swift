//
//  BypassStrategySelector.swift
//  ReaderKit
//

import LunaFetch
import LunaHTMLClassification
import LunaModels
import Foundation

/// The pure (no-I/O) policy that turns (article URL + the already-fetched direct
/// HTML) into the ordered list of `BypassStrategy` to try. This is the heavy
/// unit-test target: every ordering decision lives here, so it can be asserted
/// without touching the network.
public enum BypassStrategySelector {

    /// Ordered strategies to try for `url`, given the direct page's HTML (nil if the
    /// direct fetch failed) and — when it failed — WHY (`directFailure`). Pure — no I/O.
    ///
    /// A supported site unlock rule always runs before archive.today. The silent
    /// request leg (crawler/custom UA or spoofed Referer, JSON-LD reconstruction)
    /// is run by the resolver, not emitted here.
    /// `silentTierExhausted` marks the caller as the BROWSER tier itself — the archive
    /// reader, which is only ever opened for a page every silent strategy already failed
    /// to read. It answers a different question from `directFailure`: that one decides
    /// whether a page has earned browser recovery at all (so a 404 still fails honestly
    /// instead of parking), while this one says the browser is already here and the live
    /// page is the last untried authority.
    public static func strategies(
        for url: URL, directHTML: String?, directFailure: SaveFailureReason? = nil,
        silentTierExhausted: Bool = false, now: Date = Date()
    ) -> [BypassStrategy] {
        // The single gate decides whether ANY bypass may run. It blocks
        // product/platform pages and pages with no paywall evidence; `extracted` is
        // nil here because the resolver already returned early when the direct read
        // was readable, so the selector only sees non-readable pages.
        let decision = BypassGate.decision(for: url, html: directHTML, extracted: nil)
        // A site rule may bypass even when the gate found no generic paywall
        // evidence — but ONLY for the "no evidence" block, never overriding a
        // readable article / product page / platform link.
        let rule = SiteUnlockRules.rule(for: url)
        let ruleAllows = rule != nil
            && (decision.allowsBypass || decision == .block(.notPaywalled))
        guard decision.allowsBypass || ruleAllows else {
            return []
        }

        var strategies: [BypassStrategy] = []

        // The `?amp` rendering FIRST wherever it applies: it is silent, one request,
        // and on those hosts (News Corp Australia) it is the only thing that works at
        // all — their premium articles redirect a plain read to a subscribe page, so
        // every strategy that needs the article's own HTML has nothing to chew on.
        if AMPQueryBypass.ampQueryURL(for: url) != nil {
            strategies.append(.ampQuery)
        }

        // The Wayback Machine, both ends of the capture history, before ANY browser tier:
        // it is silent, needs no CAPTCHA, and is the only technique that can beat a
        // server-side truncation — the publisher never sent the rest of the body, so
        // nothing done to the live page can recover it. Newest capture first (right for an
        // article walled from publication), then the oldest, which predates a wall added
        // later (`.waybackPrePaywall`). Both precede a user-visible WKWebView flow, and
        // the readability gate discards a capture that carries the same wall.
        strategies.append(.waybackRaw)
        // …except that the pre-paywall end is only meaningful for an article OLD enough
        // to have been published before its publisher put a wall up. When the page's own
        // markup dates it to the last few months, that era cannot exist and the strategy
        // is not scheduled at all — saving a Wayback index lookup, which is the slowest
        // and flakiest service in the pipeline (1.7s–16s on consecutive lookups of one
        // URL) and the reason today's paywalled news used to sit on a spinner. An undated
        // page keeps the strategy: absence of a date is not evidence of youth.
        let provablyRecent = directHTML.map {
            PublicationDate.provesYounger(
                than: ArticleFetcher.prePaywallCaptureMinimumAge, html: $0, now: now)
        } ?? false
        if !provablyRecent {
            strategies.append(.waybackPrePaywall)
        }

        // A site rule → the browser-tier direct unlock before archive.today.
        if rule != nil {
            return strategies + [.directUnlock, .archiveToday]
        }

        // No rule, but the front door REFUSED the client outright (401/403/429) rather
        // than serving a wall — so nothing was learned about the page, only about who
        // asked. A WKWebView asks as a real browser (real TLS fingerprint, challenge JS
        // actually executed), which is a genuinely different question and routinely gets
        // the whole article: a free piratewires.com piece answers 429 with a Vercel
        // security checkpoint to every silent strategy and 200 with all 57 paragraphs to
        // the first browser load. Without this the page was `.failed` before the browser
        // tier was ever consulted, because `.directUnlock` was reachable only through a
        // per-host rule — and the hosts that need it most are exactly the ones the
        // upstream rule table gives up on (piratewires.com is on its `noFix` list).
        // The reader adds the same leg for ANY ruleless page it has been opened for,
        // because by then the live page is simply the last thing nobody has tried in a
        // real browser — and the direct-unlock technique (paywall scripts blocked, DOM
        // cleanup) is what soft walls fall to. Skipped for a hard-paywall host (the wall
        // is certain, so it would only delay the archive flow) and for a URL that is
        // already a snapshot.
        let browserTierMayTryLivePage = silentTierExhausted
            && !ArticleFetcher.isHardPaywallHost(url)
            && !ArticleFetcher.isArchiveTodayURL(url)
        if directFailure?.browserMayRecover == true || browserTierMayTryLivePage {
            strategies.append(.directUnlock)
        }

        // Otherwise go straight to the archive flow, with NYT's trailing-dot browser
        // pre-stage.
        if let host = url.host, TrailingDotBypass.isNYTHost(host) {
            strategies.append(.trailingDotHost)
        }
        strategies.append(.archiveToday)
        return strategies
    }
}

//
//  BypassStrategySelector.swift
//  ReaderKit
//

import Foundation

/// The pure (no-I/O) policy that turns (article URL + the already-fetched direct
/// HTML) into the ordered list of `BypassStrategy` to try. This is the heavy
/// unit-test target: every ordering decision lives here, so it can be asserted
/// without touching the network.
public enum BypassStrategySelector {

    /// Ordered strategies to try for `url`, given the direct page's HTML (nil if the
    /// direct fetch failed). Pure — no I/O.
    ///
    /// A supported site unlock rule always runs before archive.today. The silent
    /// request leg (crawler/custom UA or spoofed Referer, JSON-LD reconstruction)
    /// is run by the resolver, not emitted here.
    public static func strategies(for url: URL, directHTML: String?) -> [BypassStrategy] {
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
        // later (`.waybackPrePaywall`). Both are cheap enough to precede a user-visible
        // WKWebView flow, and the readability gate discards a capture that carries the
        // same wall.
        strategies.append(.waybackRaw)
        strategies.append(.waybackPrePaywall)

        // A site rule → the browser-tier direct unlock before archive.today.
        if rule != nil {
            return strategies + [.directUnlock, .archiveToday]
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

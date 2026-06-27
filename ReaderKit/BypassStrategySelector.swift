//
//  BypassStrategySelector.swift
//  ReaderKit
//

import Foundation

/// The pure (no-I/O) policy that turns (article URL + the already-fetched direct
/// HTML) into the ordered list of `BypassStrategy` to try. This is the heavy
/// unit-test target: every ordering decision lives here, so it can be asserted
/// without touching the network.
enum BypassStrategySelector {

    /// First-party silent strategies tried (over URLSession, from the user's own
    /// device IP) BEFORE the interactive archive.today flow. These are the same
    /// techniques browser paywall extensions use, and they matter because hard
    /// paywalls (WSJ chief among them) block the datacenter IPs that archive.today
    /// and Wayback crawl from — so the archiver gets a teaser/401 while a fetch
    /// from the reader's residential/cellular IP gets the real page:
    ///   - `.jsonLDBody`: zero-network — pull the article body straight out of the
    ///     page's JSON-LD if it's there.
    ///   - `.userAgent(.googlebot*)`: WSJ/NYT and most metered sites serve the full
    ///     text to Googlebot for SEO; the check is UA-based (an extension can't
    ///     change IP either), so the device fetch with a Googlebot UA + cookieless
    ///     session gets the article. Desktop first, mobile as a fallback (WSJ
    ///     occasionally 500s one).
    ///   - `.freshSession`: a cookieless visit resets a client-side metered counter.
    ///   - `.amp`: the AMP page is often served un-gated.
    ///   - `.waybackRaw`: a public archive snapshot (often captured ungated).
    /// Third-party reader/proxy services (1ft/smry/removepaywalls/jina) are
    /// deliberately NOT used — only first-party reads and the public archives.
    static let firstPartySilent: [BypassStrategy] = [
        .jsonLDBody,
        .userAgent(.googlebotDesktop),
        .userAgent(.googlebotMobile),
        .freshSession,
        .amp,
        .waybackRaw,
    ]

    /// Ordered strategies to try for `url`, given the direct page's HTML (nil if the
    /// direct fetch failed). Pure — no I/O.
    ///
    /// Reasoning order:
    /// 1. The hard `BypassGate` blocks a bypass (product/platform/free page) → `[]`.
    /// 2. The first-party silent chain (cheapest/highest-yield first), each tried
    ///    from the device's own IP and stopping at the first readable result.
    /// 3. NYT's trailing-dot host variant (a client-side origin trick that needs a
    ///    real browser — kept here so it's also retried as a WKWebView pre-stage).
    /// 4. archive.today as the terminal interactive fallback.
    static func strategies(for url: URL, directHTML: String?) -> [BypassStrategy] {
        // The single gate decides whether ANY bypass may run. It blocks
        // product/platform pages and pages with no paywall evidence; `extracted` is
        // nil here because the resolver already returned early when the direct read
        // was readable, so the selector only sees non-readable pages.
        guard BypassGate.decision(for: url, html: directHTML, extracted: nil).allowsBypass else {
            return []
        }

        var strategies = firstPartySilent
        // NYT's trailing-dot origin variant often clears the metered overlay, but
        // only in a real browser — kept after the silent reads so it's emitted as a
        // WKWebView pre-stage before archive.today.
        if let host = url.host, TrailingDotBypass.isNYTHost(host) {
            strategies.append(.trailingDotHost)
        }
        strategies.append(.archiveToday)
        return strategies
    }
}

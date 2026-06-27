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
    public static let firstPartySilent: [BypassStrategy] = [
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
    /// `nonArchiveBypass` defaults to the user's `BypassSettings.nonArchiveBypassEnabled`
    /// (OFF by default). When OFF, the result is the long-standing behavior — a
    /// detected paywall goes STRAIGHT to archive.today (NYT also gets its
    /// trailing-dot pre-stage). When ON, the first-party silent chain runs first.
    ///
    /// Reasoning order (when the chain is enabled):
    /// 1. The hard `BypassGate` blocks a bypass (product/platform/free page) → `[]`.
    /// 2. The first-party silent chain (cheapest/highest-yield first), each tried
    ///    from the device's own IP and stopping at the first readable result.
    /// 3. NYT's trailing-dot host variant (a client-side origin trick that needs a
    ///    real browser — kept here so it's also retried as a WKWebView pre-stage).
    /// 4. archive.today as the terminal interactive fallback.
    public static func strategies(
        for url: URL, directHTML: String?,
        nonArchiveBypass: Bool = BypassSettings.nonArchiveBypassEnabled
    ) -> [BypassStrategy] {
        // The single gate decides whether ANY bypass may run. It blocks
        // product/platform pages and pages with no paywall evidence; `extracted` is
        // nil here because the resolver already returned early when the direct read
        // was readable, so the selector only sees non-readable pages.
        let decision = BypassGate.decision(for: url, html: directHTML, extracted: nil)
        // When the user has opted in, a Bypass-Paywalls-Clean-known paywall host may
        // bypass even if the gate found no generic paywall evidence — but ONLY for the
        // "no evidence" block, never overriding a readable article / product page /
        // platform link.
        let bpcKnownPaywall = nonArchiveBypass
            && decision == .block(.notPaywalled)
            && KnownPaywallHosts.isKnown(url)
        guard decision.allowsBypass || bpcKnownPaywall else {
            return []
        }

        // Off (default): no silent reads — straight to the archive flow (+NYT
        // trailing-dot), exactly as before the non-archive strategies existed.
        var strategies: [BypassStrategy] = nonArchiveBypass ? firstPartySilent : []
        // The Bypass-Paywalls-Clean WKWebView technique: render the original URL with
        // the meter/vendor scripts blocked + a DOM-cleanup userscript, then extract.
        // Tried before the trailing-dot variant and archive.today.
        if nonArchiveBypass {
            strategies.append(.directUnlock)
        }
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

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
    /// `nonArchiveBypass` defaults to the user's `BypassSettings.nonArchiveBypassEnabled`
    /// (OFF by default).
    ///
    /// - OFF (default): the long-standing behavior — a detected paywall goes STRAIGHT
    ///   to archive.today (NYT also gets its trailing-dot pre-stage).
    /// - ON **and** the site has an unlock rule (`SiteUnlockRules`): the browser-tier
    ///   direct unlock (original URL, meter scripts blocked, referrer spoofed, DOM
    ///   cleaned) before archive.today. The silent request leg (crawler/custom UA or
    ///   spoofed Referer, JSON-LD reconstruction) is run by the resolver, not emitted
    ///   here.
    /// - ON but the site has NO rule: identical to OFF (unknown hosts are unaffected).
    public static func strategies(
        for url: URL, directHTML: String?,
        nonArchiveBypass: Bool = BypassSettings.nonArchiveBypassEnabled
    ) -> [BypassStrategy] {
        // The single gate decides whether ANY bypass may run. It blocks
        // product/platform pages and pages with no paywall evidence; `extracted` is
        // nil here because the resolver already returned early when the direct read
        // was readable, so the selector only sees non-readable pages.
        let decision = BypassGate.decision(for: url, html: directHTML, extracted: nil)
        // Opted in AND the site is in the unlock rule table: it may bypass even when
        // the gate found no generic paywall evidence — but ONLY for the "no evidence"
        // block, never overriding a readable article / product page / platform link.
        let rule = nonArchiveBypass ? SiteUnlockRules.rule(for: url) : nil
        let ruleAllows = rule != nil
            && (decision.allowsBypass || decision == .block(.notPaywalled))
        guard decision.allowsBypass || ruleAllows else {
            return []
        }

        // Opted in + a site rule → the browser-tier direct unlock before archive.today.
        if nonArchiveBypass, rule != nil {
            return [.directUnlock, .archiveToday]
        }

        // Otherwise (OFF, or ON with no rule): straight to the archive flow, with NYT's
        // trailing-dot browser pre-stage — exactly the long-standing behavior.
        var strategies: [BypassStrategy] = []
        if let host = url.host, TrailingDotBypass.isNYTHost(host) {
            strategies.append(.trailingDotHost)
        }
        strategies.append(.archiveToday)
        return strategies
    }
}

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

    /// Ordered strategies to try for `url`, given the direct page's HTML (nil if the
    /// direct fetch failed). Pure — no I/O.
    ///
    /// Reasoning order:
    /// 1. The direct HTML is present and NOT paywalled → `[]` (caller already has it).
    /// 2. A per-host rule exists → its strategy list (BPC parity), then normalized.
    /// 3. Otherwise build a generic list from the paywall signals, then normalize.
    ///
    /// Normalization (always applied last) de-dups, drops `.jsonLDBody` when the HTML
    /// carries no `articleBody`, and enforces the invariants: silent strategies
    /// precede WKWebView-only ones, and `.archiveToday` is always last.
    static func strategies(for url: URL, directHTML: String?) -> [BypassStrategy] {
        if let directHTML, !pageLooksPaywalled(directHTML) {
            return []
        }

        let raw: [BypassStrategy]
        if let rule = BypassRuleTable.rule(for: url) {
            raw = rule.strategies
        } else {
            raw = genericStrategies(directHTML: directHTML)
        }
        return normalize(raw, directHTML: directHTML)
    }

    /// The fallback list for an unknown, paywalled host. Cheap-first: JSON-LD body,
    /// then client-side state tricks, then archive/proxy network fallbacks, with the
    /// third-party reader pages and archive.today last.
    private static func genericStrategies(directHTML: String?) -> [BypassStrategy] {
        let declaresHardLock = directHTML.map(PaywallDetector.htmlDeclaresLocked) ?? false
        var list: [BypassStrategy] = [.jsonLDBody]
        // A server-side `locked` declaration means cookie/origin client tricks can't
        // win — skip them and go straight to archive/proxy sources.
        if !declaresHardLock {
            list += [.freshSession, .trailingDotHost]
        }
        list += [
            .amp, .waybackRaw, .jinaReader, .ladderProxy(.oneFt),
            .thirdPartyWeb(.smry), .thirdPartyWeb(.removePaywalls),
            .thirdPartyWeb(.removePaywall), .archiveToday,
        ]
        return list
    }

    /// De-dups (first occurrence wins), drops `.jsonLDBody` when the HTML has no
    /// `articleBody` to recover, and enforces the ordering invariants: all silent
    /// strategies first (in their relative order), then WKWebView-only ones, with
    /// `.archiveToday` forced to the very end.
    private static func normalize(_ strategies: [BypassStrategy], directHTML: String?) -> [BypassStrategy] {
        let htmlHasArticleBody = directHTML.map(Self.htmlContainsJSONLDArticleBody) ?? false

        var seen: Set<String> = []
        let deduped = strategies.filter { strategy in
            if strategy == .jsonLDBody, !htmlHasArticleBody { return false }
            let key = String(describing: strategy)
            return seen.insert(key).inserted
        }

        let silent = deduped.filter { $0.runsSilently }
        let webOnly = deduped.filter { !$0.runsSilently && $0 != .archiveToday }
        let archive = deduped.contains(.archiveToday) ? [BypassStrategy.archiveToday] : []
        return silent + webOnly + archive
    }

    /// Whether the page reads as paywalled for selection purposes: the publisher's
    /// schema.org `locked` declaration, or a gate-marker in the visible text.
    private static func pageLooksPaywalled(_ html: String) -> Bool {
        if PaywallDetector.htmlDeclaresLocked(html) { return true }
        let lowered = html.lowercased()
        return PaywallDetector.gateMarkers.contains { lowered.contains($0) }
    }

    /// Cheap, dependency-free check for a JSON-LD `articleBody` somewhere in the page
    /// (so `.jsonLDBody` is only offered when there's a body to recover). Matches the
    /// key whether or not the JSON has whitespace around the colon.
    static func htmlContainsJSONLDArticleBody(_ html: String) -> Bool {
        let compact = html.lowercased().filter { !$0.isWhitespace }
        return compact.contains("\"articlebody\":")
    }
}

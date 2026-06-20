//
//  BypassRuleTable.swift
//  ReaderKit
//

import Foundation

/// A per-host bypass rule: the ordered strategies to try for a known publisher,
/// best-first. Modeled on Bypass Paywalls Clean's per-site object so its hard-won
/// per-site knowledge is easy to port. A rule's `strategies` is the verbatim order
/// `BypassStrategySelector` returns for a matching host (de-duped + ordering
/// invariants still applied by the selector).
struct BypassRule: Equatable {
    /// Registrable domain this rule matches (apex; also matches any subdomain).
    let domain: String
    /// Ordered strategies to try, best-first for this publisher. Silent strategies
    /// run in the background path; WKWebView ones in the archive reader.
    let strategies: [BypassStrategy]
}

/// The static, in-app per-host rule table — the single source of truth for "what do
/// we try for host X, in what order." Kept a Swift literal (no remote config) so
/// there's no server a takedown could target; updates ship with the app.
enum BypassRuleTable {

    /// The rule whose `domain` is `url`'s host or a parent of it (apex or subdomain
    /// match; a trailing dot on the host is tolerated), or nil when no rule matches.
    static func rule(for url: URL) -> BypassRule? {
        guard var host = url.host?.lowercased() else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        return rules.first { rule in
            host == rule.domain || host.hasSuffix("." + rule.domain)
        }
    }

    /// Seed rule set. Strategies are ordered cheap/silent-first, WKWebView fallbacks
    /// last, with `.archiveToday` always terminal. Port more from BPC's `sites.js`
    /// over time. The third-party services appear as ordered fallbacks per the owner
    /// directive ("more fallbacks than archive.is").
    static let rules: [BypassRule] = [
        // Client-side cookie/origin meter — the trailing-dot trick is confirmed here.
        BypassRule(domain: "nytimes.com", strategies: [
            .trailingDotHost, .jsonLDBody, .waybackRaw, .ladderProxy(.oneFt),
            .jinaReader, .thirdPartyWeb(.smry), .thirdPartyWeb(.removePaywalls),
            .thirdPartyWeb(.removePaywall), .archiveToday,
        ]),
        // Hard server-side paywalls — body rarely ships unauthenticated, so lead with
        // a crawler UA (where honored) then archive/proxy fallbacks.
        BypassRule(domain: "wsj.com", strategies: [
            .userAgent(.googlebotDesktop), .waybackRaw, .ladderProxy(.oneFt),
            .thirdPartyWeb(.removePaywalls), .thirdPartyWeb(.removePaywall),
            .thirdPartyWeb(.smry), .archiveToday,
        ]),
        BypassRule(domain: "ft.com", strategies: [
            .userAgent(.googlebotDesktop), .waybackRaw, .ladderProxy(.oneFt),
            .thirdPartyWeb(.removePaywalls), .thirdPartyWeb(.removePaywall),
            .thirdPartyWeb(.smry), .archiveToday,
        ]),
        BypassRule(domain: "economist.com", strategies: [
            .userAgent(.googlebotDesktop), .waybackRaw, .ladderProxy(.oneFt),
            .thirdPartyWeb(.removePaywalls), .thirdPartyWeb(.removePaywall), .archiveToday,
        ]),
        BypassRule(domain: "barrons.com", strategies: [
            .userAgent(.googlebotDesktop), .amp, .waybackRaw, .ladderProxy(.oneFt),
            .thirdPartyWeb(.removePaywalls), .archiveToday,
        ]),
        // Social-virality + ships a JSON-LD articleBody alongside the locked flag.
        BypassRule(domain: "bloomberg.com", strategies: [
            .jsonLDBody, .referer(.twitter), .referer(.facebook), .waybackRaw,
            .ladderProxy(.oneFt), .thirdPartyWeb(.smry), .thirdPartyWeb(.removePaywalls),
            .archiveToday,
        ]),
        // Bingbot is honored by the Haaretz group.
        BypassRule(domain: "haaretz.com", strategies: [
            .userAgent(.bingbot), .waybackRaw, .ladderProxy(.oneFt),
            .thirdPartyWeb(.removePaywalls), .archiveToday,
        ]),
        // Metered / soft walls — cheap client-side tricks first, then proxies.
        BypassRule(domain: "washingtonpost.com", strategies: [
            .jsonLDBody, .freshSession, .trailingDotHost, .amp, .waybackRaw,
            .ladderProxy(.oneFt), .thirdPartyWeb(.smry), .thirdPartyWeb(.removePaywalls),
            .archiveToday,
        ]),
        BypassRule(domain: "newyorker.com", strategies: [
            .jsonLDBody, .freshSession, .waybackRaw, .ladderProxy(.oneFt),
            .thirdPartyWeb(.smry), .thirdPartyWeb(.removePaywalls), .archiveToday,
        ]),
        BypassRule(domain: "theatlantic.com", strategies: [
            .jsonLDBody, .freshSession, .waybackRaw, .ladderProxy(.oneFt),
            .thirdPartyWeb(.smry), .thirdPartyWeb(.removePaywalls), .archiveToday,
        ]),
        BypassRule(domain: "wired.com", strategies: [
            .userAgent(.googlebotDesktop), .jsonLDBody, .amp, .waybackRaw,
            .ladderProxy(.oneFt), .thirdPartyWeb(.smry), .archiveToday,
        ]),
        BypassRule(domain: "businessinsider.com", strategies: [
            .jsonLDBody, .freshSession, .amp, .waybackRaw, .ladderProxy(.oneFt),
            .thirdPartyWeb(.smry), .archiveToday,
        ]),
        BypassRule(domain: "telegraph.co.uk", strategies: [
            .userAgent(.googlebotDesktop), .jsonLDBody, .waybackRaw, .ladderProxy(.oneFt),
            .thirdPartyWeb(.removePaywalls), .archiveToday,
        ]),
        BypassRule(domain: "thetimes.co.uk", strategies: [
            .userAgent(.googlebotDesktop), .waybackRaw, .ladderProxy(.oneFt),
            .thirdPartyWeb(.removePaywalls), .archiveToday,
        ]),
        BypassRule(domain: "latimes.com", strategies: [
            .jsonLDBody, .freshSession, .amp, .waybackRaw, .ladderProxy(.oneFt),
            .thirdPartyWeb(.removePaywalls), .archiveToday,
        ]),
        BypassRule(domain: "bostonglobe.com", strategies: [
            .jsonLDBody, .waybackRaw, .ladderProxy(.oneFt),
            .thirdPartyWeb(.removePaywalls), .archiveToday,
        ]),
        BypassRule(domain: "nikkei.com", strategies: [
            .waybackRaw, .ladderProxy(.oneFt), .thirdPartyWeb(.removePaywalls), .archiveToday,
        ]),
        BypassRule(domain: "seekingalpha.com", strategies: [
            .userAgent(.googlebotDesktop), .waybackRaw, .ladderProxy(.oneFt), .archiveToday,
        ]),
        BypassRule(domain: "hbr.org", strategies: [
            .jsonLDBody, .waybackRaw, .ladderProxy(.oneFt),
            .thirdPartyWeb(.removePaywalls), .archiveToday,
        ]),
        BypassRule(domain: "theinformation.com", strategies: [
            .waybackRaw, .ladderProxy(.oneFt), .thirdPartyWeb(.removePaywalls), .archiveToday,
        ]),
        BypassRule(domain: "foreignpolicy.com", strategies: [
            .jsonLDBody, .waybackRaw, .ladderProxy(.oneFt), .archiveToday,
        ]),
        BypassRule(domain: "foreignaffairs.com", strategies: [
            .jsonLDBody, .waybackRaw, .ladderProxy(.oneFt), .archiveToday,
        ]),
    ]
}

//
//  CrawlerIdentityLadder.swift
//  LunaPaywallBypass
//

import Foundation

/// Picks WHICH fetcher identities a paywalled page is worth re-fetching as, and in
/// what order. Pure (no I/O), so the whole policy is unit-testable.
///
/// One spoof is not a strategy. A publisher's edge refuses identities one token at a
/// time, and the sets it lets through do not nest: measured over 28 paywalled hosts
/// (2026-08-22, one residential IP), the widest single identity reached 18 of them,
/// Claude-User alone got into leparisien.fr, only the assistant fetchers got into
/// haaretz.com, and only the search-crawler tokens got into law.com. So the ladder
/// spends its attempts on identities that fail DIFFERENTLY rather than on the one
/// with the best average — Googlebot alone (what a crawler-UA bypass has always
/// meant) loses every host whose blocklist has since learned that token.
///
/// The attempts fan out concurrently (`ArticleResolver.firstQualifying`), so the
/// order decides which readable answer WINS, not how long the tier takes, and the
/// cap is about how many simultaneous requests one publisher should see from one
/// save — not about latency.
public enum CrawlerIdentityLadder {

    /// How many identities one page may be re-fetched as. The attempts run at the
    /// same time, so this bounds two things a longer ladder would strain: how many
    /// simultaneous requests one save costs one publisher, and how many page bodies
    /// (each up to `ArticleFetcher.maxBytes`) a memory-limited share/action
    /// extension holds at once.
    public static let maximumAttempts = 4

    /// Every identity worth a generic attempt, best-first. `.xaiImageFetch` and
    /// `.googleInspectionTool` lead on measured reach; `.googlebotDesktop` follows
    /// because it is the identity the bundled rule table names for 84 sites, so it
    /// carries the most evidence of actually unlocking rather than merely answering
    /// 200; `.claudeUser` is next for being the only way into some hosts. The list
    /// runs deeper than `maximumAttempts` so a refused identity can be REPLACED
    /// rather than lost. `.facebookbot` stays out — it identifies a link-preview
    /// scrape of one URL, and only a rule that names it sends it.
    static let rankedIdentities: [CrawlerAgent] = [
        .xaiImageFetch, .googleInspectionTool, .googlebotDesktop, .claudeUser,
        .openAIFileDownloader, .googleReadAloud, .bingbot, .googlebotMobile,
    ]

    /// Identities a host was measured REFUSING outright (a 4xx, or a reset
    /// connection, where a sibling identity got the page) — 2026-08-22. Dropping
    /// them frees the slot for an identity that can answer, which is what makes the
    /// cap affordable. A host not listed here gets the ranked ladder as-is.
    ///
    /// One IP, one day, so an entry can be wrong for a reader somewhere else. The
    /// table is shaped so that costs coverage rather than correctness: it only ever
    /// removes attempts, and a page that loses one still gets the rest of the ladder,
    /// the archives and the browser tier. Hosts that refused every identity equally
    /// (wsj.com, bloomberg.com, ft.com, economist.com) are deliberately ABSENT — a
    /// 401 from them arrives in under 0.2s, so one cheap probe per identity is worth
    /// keeping in case the next reader's IP is treated differently.
    static let refusedIdentities: [String: Set<CrawlerAgent>] = [
        // Serves all three assistant fetchers, 403s every search-crawler token.
        "haaretz.com": googleAndBingTokens,
        "haaretz.co.il": googleAndBingTokens,
        "themarker.com": googleAndBingTokens,
        "nbcnews.com": googleAndBingTokens.union([.claudeUser]),
        // Resets the connection for the crawler tokens rather than answering.
        "telegraph.co.uk": googleAndBingTokens.union([.claudeUser]),
        // The one host in the set that serves ONLY Claude-User.
        "leparisien.fr": Set(CrawlerAgent.allCases).subtracting([.claudeUser]),
        // Redirects the assistant fetchers to a dead end; the crawler tokens get the page.
        "law.com": [.claudeUser, .openAIFileDownloader, .xaiImageFetch],
        "nytimes.com": [.claudeUser],
        "newyorker.com": [.claudeUser],
        "theatlantic.com": [.claudeUser],
        "thetimes.com": [.claudeUser],
        // Gannett's edge answers 402 to the assistant fetchers and 403 to read-aloud.
        "azcentral.com": gannettRefusals,
        "freep.com": gannettRefusals,
        "jsonline.com": gannettRefusals,
    ]

    private static let googleAndBingTokens: Set<CrawlerAgent> = [
        .googlebotDesktop, .googlebotMobile, .bingbot, .googleInspectionTool, .googleReadAloud,
    ]

    private static let gannettRefusals: Set<CrawlerAgent> = [
        .claudeUser, .openAIFileDownloader, .googleReadAloud,
    ]

    /// The identities to re-fetch `url` as, in attempt order — the ranked ladder
    /// minus what this host refuses and minus `alreadyTried` (the identity a site
    /// unlock rule's own request leg is spending), capped at `maximumAttempts`.
    public static func identities(
        for url: URL, alreadyTried: CrawlerAgent? = nil
    ) -> [CrawlerAgent] {
        var refused = HostSuffixLookup.value(for: url, in: refusedIdentities) ?? []
        if let alreadyTried { refused.insert(alreadyTried) }
        return Array(rankedIdentities.filter { !refused.contains($0) }.prefix(maximumAttempts))
    }
}

//
//  BypassStrategy.swift
//  ReaderKit
//

import Foundation

/// One technique for getting a readable article past a paywall. Ordered lists of
/// these are produced by `BypassStrategySelector` and consumed by `BypassRunner`
/// (silent, URLSession path) and `ArchiveWebReaderViewController` (WKWebView path).
///
/// Each case is either a URLSession request transform usable in the background
/// ingest path, or WKWebView-only (user-visible, needs a real browser/JS/CAPTCHA):
/// `.directUnlock` and `.archiveToday` are the two WKWebView-only cases: every
/// consumer that needs the split (`BypassPlan`, `BypassRunner`) switches on those
/// two cases directly rather than through a shared predicate.
public enum BypassStrategy: Equatable {
    /// Re-parse the HTML we already have, lifting the full body out of a
    /// `<script type="application/ld+json">` `articleBody`. Zero network. Silent.
    case jsonLDBody
    /// Re-fetch with a specific crawler User-Agent (and the matching crawler XFF).
    /// Silent.
    case userAgent(CrawlerAgent)
    /// Re-fetch sending a spoofed `Referer` (and otherwise the normal UA). Silent.
    case referer(RefererOrigin)
    /// Re-fetch the trailing-dot FQDN variant of the host. Silent (URLSession) and
    /// also usable in WKWebView.
    case trailingDotHost
    /// Re-fetch with no cookies via a fresh ephemeral session. Silent.
    case freshSession
    /// Discover the AMP URL (`rel=amphtml`) and fetch it. Silent.
    case amp
    /// Fetch the `?amp` variant of the article URL directly, for hosts that route
    /// their AMP rendering by query and serve the full body in it (`AMPQueryBypass`).
    /// Needs no direct HTML — which is the point: on those sites the direct read is
    /// redirected to a subscribe page, so there is no `rel=amphtml` to discover.
    /// Silent.
    case ampQuery
    /// Wayback: resolve the newest 200 snapshot (CDX, then Availability) and fetch
    /// the raw `id_` replay. Silent.
    case waybackRaw
    /// Wayback: resolve the oldest 200 snapshot and fetch the raw `id_`
    /// replay — the capture that predates a wall the publisher added after
    /// publication (the only thing that works on a site whose archive went
    /// free-then-metered, e.g. The Paris Review's interview archive). Runs
    /// after `.waybackRaw`, whose newest capture is the right answer for an
    /// article walled from publication. Silent.
    case waybackPrePaywall
    /// r.jina.ai reader proxy (`https://r.jina.ai/<url>`) → Markdown/HTML. Silent.
    case jinaReader
    /// A server-rendering proxy (1ft.io) whose response is plain HTML a URLSession
    /// can extract. Silent.
    case ladderProxy(LadderProxy)
    /// Load the original article URL in the WKWebView with the paywall/meter
    /// vendor scripts blocked (a compiled `WKContentRuleList`) and a
    /// DOM-cleanup userscript injected (remove overlays, unhide the clamped
    /// body, restore scroll). The site's own JS renders the article while
    /// the meter cannot run, so the rendered DOM is extractable.
    /// WKWebView-only — the core technique. Tried before archive.today (only
    /// when the user opts in).
    case directUnlock
    /// archive.is snapshot via the interactive WKWebView reader. WKWebView-only,
    /// always the terminal (most expensive/hostile) strategy.
    case archiveToday
}

/// Fetcher identities a paywall may serve full text to — search crawlers a
/// publisher whitelists for SEO/social, and the assistant-side fetchers that
/// retrieve one page for one user. `xForwardedFor` carries a real crawler IP so a
/// server-side reverse-DNS-lite check can pass; many majors IP-verify crawlers, so
/// this only helps sites that honor the UA.
///
/// The set is deliberately DIVERSE rather than ranked-best-first, because a site
/// refuses identities one token at a time: measured over 28 paywalled hosts
/// (2026-08-22, one residential IP, homepage GET), no identity reached more than
/// 18 of them and the reachable sets do not nest. haaretz.com answers 403 to
/// Googlebot, Bingbot and both Google fetchers while serving all three assistant
/// fetchers; leparisien.fr answers 403 to everything except Claude-User;
/// nbcnews.com refuses the Google/Bing crawler tokens and serves the assistant
/// ones; telegraph.co.uk resets the connection for those same crawler tokens.
/// `CrawlerIdentityLadder` is what turns that into an attempt order.
public enum CrawlerAgent: Hashable, CaseIterable {
    case googlebotDesktop
    case googlebotMobile
    case bingbot
    case facebookbot
    /// Google's Search Console fetcher. A Google identity that carries none of the
    /// `Googlebot` token, so a blocklist keyed on that token lets it through.
    case googleInspectionTool
    /// Google's read-aloud fetcher — a mobile Chrome UA with a Google product token
    /// appended, so it reads as a browser to a token-matching blocklist.
    case googleReadAloud
    /// Anthropic's user-initiated fetcher (Claude fetching one page a person asked
    /// for). Widely refused by publishers, and the ONLY identity some sites accept.
    case claudeUser
    /// OpenAI's file-download fetcher, as it identifies itself: a bare product name
    /// with no `bot` token and no crawler URL.
    case openAIFileDownloader
    /// xAI's image-fetch API client. The broadest reach of the set as measured.
    case xaiImageFetch

    /// The literal User-Agent string to send.
    public var userAgent: String {
        switch self {
        case .googlebotDesktop:
            return "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
        case .googlebotMobile:
            return "Mozilla/5.0 (Linux; Android 6.0.1; Nexus 5X Build/MMB29P) "
                + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/80.0.3987.92 Mobile Safari/537.36 "
                + "(compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
        case .bingbot:
            return "Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)"
        case .facebookbot:
            return "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)"
        case .googleInspectionTool:
            // The same string the bundled rule table already spoofs for one host, so
            // the named identity and that rule cannot drift apart.
            return "Mozilla/5.0 (compatible; Google-InspectionTool/1.0)"
        case .googleReadAloud:
            return "Mozilla/5.0 (Linux; Android 7.0; Moto G (4)) AppleWebKit/537.36 "
                + "(KHTML, like Gecko) Chrome/59.0.3071.125 Mobile Safari/537.36 "
                + "(compatible; Google-Read-Aloud; "
                + "+https://developers.google.com/search/docs/crawling-indexing/overview-google-crawlers)"
        case .claudeUser:
            return "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; "
                + "Claude-User/1.0; +Claude-User@anthropic.com)"
        case .openAIFileDownloader:
            return "OpenAI File Downloader"
        case .xaiImageFetch:
            return "XaiImageApiFetch/1.0"
        }
    }

    /// A real crawler IP for the `X-Forwarded-For` header. Only the Google
    /// identities send one: the header's only use is a reverse-proxy allowlist keyed
    /// to Google's ranges, and claiming a Google IP under a non-Google token is a
    /// contradiction a bot-management edge can match on.
    public var xForwardedFor: String? {
        switch self {
        case .googlebotDesktop, .googlebotMobile, .googleInspectionTool, .googleReadAloud:
            return "66.249.66.1"
        case .bingbot, .facebookbot, .claudeUser, .openAIFileDownloader, .xaiImageFetch:
            return nil
        }
    }
}

/// Referer origins that trip "came from search/social" free-read allowances.
public enum RefererOrigin: String, Equatable {
    case google
    case facebook
    case twitter

    /// The literal `Referer` header value to send.
    public var url: String {
        switch self {
        case .google:
            return "https://www.google.com/"
        case .facebook:
            return "https://www.facebook.com/"
        case .twitter:
            return "https://t.co/"
        }
    }
}

/// Silent (URLSession-extractable) ladder-style proxies. 1ft.io is the live
/// everywall/ladder-family successor to 12ft.io; it server-renders the article, so a
/// plain GET of its URL yields HTML the extractor can read.
public enum LadderProxy: Equatable {
    case oneFt

    /// The proxy URL for `article`, or nil if it can't be formed. The article URL is
    /// appended raw (12ft-style path prefix), keeping its own scheme/slashes.
    public func url(for article: URL) -> URL? {
        switch self {
        case .oneFt:
            return URL(string: "https://1ft.io/" + article.absoluteString)
        }
    }
}

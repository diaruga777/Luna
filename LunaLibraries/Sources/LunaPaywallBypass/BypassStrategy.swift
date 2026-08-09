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
    /// Re-fetch the trailing-dot FQDN variant of the host. Silent (URLSession) AND
    /// usable in WKWebView (the former NYT-only pre-stage).
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
    /// Wayback: resolve the OLDEST 200 snapshot and fetch the raw `id_` replay — the
    /// capture that predates a wall the publisher added after publication (the only
    /// thing that works on a site whose archive went free-then-metered, e.g. The Paris
    /// Review's interview archive). Runs AFTER `.waybackRaw`, whose newest capture is
    /// the right answer for an article walled from publication. Silent.
    case waybackPrePaywall
    /// r.jina.ai reader proxy (`https://r.jina.ai/<url>`) → Markdown/HTML. Silent.
    case jinaReader
    /// A server-rendering proxy (1ft.io) whose response is plain HTML a URLSession
    /// can extract. Silent.
    case ladderProxy(LadderProxy)
    /// Load the ORIGINAL article URL in the WKWebView with the paywall/meter
    /// vendor scripts blocked (a compiled `WKContentRuleList`) and a DOM-cleanup
    /// userscript injected (remove overlays, unhide the clamped body, restore
    /// scroll). The site's own JS renders the article while the meter can't run, so
    /// the rendered DOM is extractable. WKWebView-only — the core technique.
    /// Tried before archive.today (only when the user opts in).
    case directUnlock
    /// archive.is snapshot via the interactive WKWebView reader. WKWebView-only,
    /// always the terminal (most expensive/hostile) strategy.
    case archiveToday
}

/// Crawler identities a paywall may whitelist for SEO/social. `xForwardedFor`
/// carries a real crawler IP so a server-side reverse-DNS-lite check can pass; many
/// majors IP-verify crawlers, so this only helps sites that honor the UA.
public enum CrawlerAgent: Equatable {
    case googlebotDesktop
    case googlebotMobile
    case bingbot
    case facebookbot

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
        }
    }

    /// A real crawler IP for the `X-Forwarded-For` header (Googlebot only; Bing and
    /// Facebook don't benefit from an XFF claim).
    public var xForwardedFor: String? {
        switch self {
        case .googlebotDesktop, .googlebotMobile:
            return "66.249.66.1"
        case .bingbot, .facebookbot:
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

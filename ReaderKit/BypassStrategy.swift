//
//  BypassStrategy.swift
//  ReaderKit
//

import Foundation

/// One technique for getting a readable article past a paywall. Ordered lists of
/// these are produced by `BypassStrategySelector` and consumed by `BypassRunner`
/// (silent, URLSession path) and `ArchiveWebReaderViewController` (WKWebView path).
///
/// Each case is either `runsSilently` — a URLSession request transform usable in the
/// background ingest path — or WKWebView-only (user-visible, needs a real
/// browser/JS/CAPTCHA). The split is explicit in the type so the resolver and the web
/// reader can each filter to the strategies they can actually run.
enum BypassStrategy: Equatable {
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
    /// Wayback: resolve the newest 200 snapshot (CDX, then Availability) and fetch
    /// the raw `id_` replay. Silent.
    case waybackRaw
    /// r.jina.ai reader proxy (`https://r.jina.ai/<url>`) → Markdown/HTML. Silent.
    case jinaReader
    /// A server-rendering proxy (1ft.io) whose response is plain HTML a URLSession
    /// can extract. Silent.
    case ladderProxy(LadderProxy)
    /// A third-party reader page that only renders client-side (smry.ai,
    /// removepaywall(s).com). WKWebView-only.
    case thirdPartyWeb(ThirdPartyWebService)
    /// archive.today snapshot via the interactive WKWebView reader. WKWebView-only,
    /// always the terminal (most expensive/hostile) strategy.
    case archiveToday

    /// Whether this strategy can run in the background URLSession path. The
    /// client-rendered third-party pages and archive.today are not silent.
    var runsSilently: Bool {
        switch self {
        case .archiveToday, .thirdPartyWeb:
            return false
        default:
            return true
        }
    }

    /// A stable, human-readable name for diagnostics (Replay `bypassStrategy`
    /// events). Includes the associated value so consumers can tell variants apart.
    var replayName: String {
        switch self {
        case .jsonLDBody: return "jsonLDBody"
        case let .userAgent(agent): return "userAgent(\(agent))"
        case let .referer(origin): return "referer(\(origin.rawValue))"
        case .trailingDotHost: return "trailingDotHost"
        case .freshSession: return "freshSession"
        case .amp: return "amp"
        case .waybackRaw: return "waybackRaw"
        case .jinaReader: return "jinaReader"
        case let .ladderProxy(proxy): return "ladderProxy(\(proxy))"
        case let .thirdPartyWeb(service): return "thirdPartyWeb(\(service))"
        case .archiveToday: return "archiveToday"
        }
    }
}

/// Crawler identities a paywall may whitelist for SEO/social. `xForwardedFor`
/// carries a real crawler IP so a server-side reverse-DNS-lite check can pass; many
/// majors IP-verify crawlers, so this only helps sites that honor the UA.
enum CrawlerAgent: Equatable {
    case googlebotDesktop
    case googlebotMobile
    case bingbot

    /// The literal User-Agent string to send.
    var userAgent: String {
        switch self {
        case .googlebotDesktop:
            return "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
        case .googlebotMobile:
            return "Mozilla/5.0 (Linux; Android 6.0.1; Nexus 5X Build/MMB29P) "
                + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/80.0.3987.92 Mobile Safari/537.36 "
                + "(compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
        case .bingbot:
            return "Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)"
        }
    }

    /// A real crawler IP for the `X-Forwarded-For` header (Googlebot only; Bing
    /// doesn't benefit from an XFF claim).
    var xForwardedFor: String? {
        switch self {
        case .googlebotDesktop, .googlebotMobile:
            return "66.249.66.1"
        case .bingbot:
            return nil
        }
    }
}

/// Referer origins that trip "came from search/social" free-read allowances.
enum RefererOrigin: String, Equatable {
    case google
    case facebook
    case twitter

    /// The literal `Referer` header value to send.
    var url: String {
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
enum LadderProxy: Equatable {
    case oneFt

    /// The proxy URL for `article`, or nil if it can't be formed. The article URL is
    /// appended raw (12ft-style path prefix), keeping its own scheme/slashes.
    func url(for article: URL) -> URL? {
        switch self {
        case .oneFt:
            return URL(string: "https://1ft.io/" + article.absoluteString)
        }
    }
}

/// Client-rendered third-party reader pages. Their article only materializes after a
/// client-side render, so they need a real WKWebView (not a URLSession GET).
enum ThirdPartyWebService: Equatable {
    case smry
    case removePaywalls
    case removePaywall

    /// The reader-page URL for `article`, or nil if it can't be formed. Path-prefix
    /// services append the article URL raw; removepaywall.com percent-encodes it
    /// because it rides in a real query parameter.
    func url(for article: URL) -> URL? {
        switch self {
        case .smry:
            return URL(string: "https://smry.ai/" + article.absoluteString)
        case .removePaywalls:
            return URL(string: "https://removepaywalls.com/" + article.absoluteString)
        case .removePaywall:
            guard let encoded = article.absoluteString.addingPercentEncoding(
                withAllowedCharacters: .urlQueryValueAllowed) else { return nil }
            return URL(string: "https://www.removepaywall.com/search?url=" + encoded)
        }
    }
}

private extension CharacterSet {
    /// Characters allowed unescaped in a single URL query-parameter *value*. Starts
    /// from `.urlQueryAllowed` and removes the sub-delimiters that are significant
    /// inside a value (`&`, `=`, `+`, `?`, `/`, `:`, …) so a nested `https://…?a=b`
    /// is encoded whole rather than splitting the outer query.
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?/:#@!$'()*,;")
        return set
    }()
}

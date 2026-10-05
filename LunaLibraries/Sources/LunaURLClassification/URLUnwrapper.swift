//
//  URLUnwrapper.swift
//  Luna
//

import Foundation
import LunaModels

/// The canonical result of unwrapping one incoming URL. `url` is always the best
/// URL to use downstream (the original if nothing matched), already
/// tracking-stripped. `didUnwrap` lets callers log / repoint a store only on a
/// real change.
public struct UnwrapResult: Equatable {
    /// The best URL to use downstream — the unwrapped target when a handler fired,
    /// else the original input. Always tracking-param-stripped.
    public let url: URL
    /// Whether a handler actually changed the URL (the unwrapped target differs
    /// from the input, ignoring tracking-param stripping).
    public let didUnwrap: Bool
}

/// How a matched handler resolves the underlying URL.
public enum UnwrapResolution {
    /// Pure, offline resolution (Facebook deep link / shim, Google News classic).
    /// `nil` ⇒ matched the host but found no recoverable target (caller keeps the
    /// original URL).
    case immediate(URL?)
    /// Network-backed resolution (Apple News page fetch, Google News new-style
    /// batchexecute, link shortener HEAD-redirect). `nil` ⇒ no recoverable target.
    case fetch((URLSession) async -> URL?)
}

/// One wrapper definition. New wrappers are added by appending a value to
/// `URLUnwrapper.handlers`; the dispatch needs no edits.
public struct WrapperHandler {
    /// Whether this handler applies to a URL with the given scheme/host. Host-suffix
    /// awareness is the handler's own responsibility.
    public let matches: (_ scheme: String?, _ host: String?) -> Bool
    /// Given a matching URL, how to resolve it (offline vs network).
    public let resolve: (URL) -> UnwrapResolution
}

/// THE app-wide URL unwrapper: turns a wrapper/redirect URL (Apple News, Google
/// News, link shorteners, Facebook deep links/shims) into the real underlying
/// publisher URL, offline-first and deterministically, as the first thing that
/// runs on any incoming URL. Built as an extensible `[WrapperHandler]` registry
/// over the well-tested pure parsers in `NewsAggregatorUnwrapper` — only the
/// dispatch is new. Pure and dependency-free, so the main app and every
/// extension unwrap identically.
public enum URLUnwrapper {

    /// Parses an incoming user/share URL into the one canonical URL every ingest
    /// surface stores and processes. This is deliberately the only URL-entry gate:
    /// it trims input, optionally accepts a host-shaped manual entry, rejects
    /// non-web schemes, applies offline wrapper resolution, and strips tracking
    /// parameters. Network-backed unwraps still occur in `IngestPipeline`.
    public static func ingestURL(from string: String, allowBareHost: Bool = false) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parsed: URL?
        if let url = URL(string: trimmed), url.scheme != nil {
            parsed = url
        } else if allowBareHost,
                  trimmed.contains("."),
                  trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
            parsed = URL(string: "https://\(trimmed)")
        } else {
            parsed = nil
        }

        guard let parsed else { return nil }
        let normalized = URLBehaviorPolicy.pluginsOnly ? parsed : unwrapOffline(parsed).url
        guard let normalizedScheme = normalized.scheme?.lowercased(),
              (normalizedScheme == "http" || normalizedScheme == "https"),
              normalized.host?.isEmpty == false
        else { return nil }
        return normalized
    }

    /// EXTEND HERE: add a wrapper by appending a handler. Matchers are otherwise
    /// disjoint; order matters only on overlap (Facebook runs first because an
    /// `fbrpc://` deep link has no http host and must be tried before the host gate).
    ///
    /// `.interstitial` MUST stay last: a subscribe / sign-in / cookie-check
    /// interstitial lives on the publisher's own host, so it is the one handler
    /// identified by PATH rather than host and its matcher accepts every http(s)
    /// URL. The dispatch loop `break`s after the first matcher that fires, so
    /// anywhere earlier it would shadow every handler below it.
    public static let handlers: [WrapperHandler] = [
        .facebook,
        .googleNews,
        .googleShare,
        .appleNews,
        .shorteners(redirectShortenerHosts.union(amazonShortLinkHosts)),
        .interstitial,
    ]

    /// THE app-wide entry. Run once per incoming URL on EVERY surface. Resolves the
    /// offline fast path inline and performs network only when a matched handler
    /// requires it. Always returns a usable, tracking-stripped URL.
    public static func unwrap(_ url: URL, session: URLSession = .shared) async -> UnwrapResult {
        if URLBehaviorPolicy.pluginsOnly { return UnwrapResult(url: url, didUnwrap: false) }
        let scheme = url.scheme?.lowercased()
        let host = url.host?.lowercased()
        for handler in handlers where handler.matches(scheme, host) {
            switch handler.resolve(url) {
            case .immediate(let target):
                if let target { return result(unwrapped: target) }
            case .fetch(let perform):
                if let target = await perform(session) { return result(unwrapped: target) }
            }
            // Matched the host but found no recoverable target: stop scanning (a
            // News+ exclusive, a shortener that stays on-host) and keep the original.
            break
        }
        return result(unchanged: url)
    }

    /// Offline-only fast path for INPUT GATES that can't await / must not block, and
    /// that need a real http(s) URL before a `hasPrefix("http")` check. Resolves
    /// every `.immediate` handler (Facebook deep link/shim, Google News classic);
    /// leaves `.fetch` wrappers untouched for the async `unwrap` to finish at the
    /// choke point. Pure.
    public static func unwrapOffline(_ url: URL) -> UnwrapResult {
        if URLBehaviorPolicy.pluginsOnly { return UnwrapResult(url: url, didUnwrap: false) }
        let scheme = url.scheme?.lowercased()
        let host = url.host?.lowercased()
        for handler in handlers where handler.matches(scheme, host) {
            if case .immediate(let target) = handler.resolve(url), let target {
                return result(unwrapped: target)
            }
            break
        }
        return result(unchanged: url)
    }

    /// True when `string` names a DIFFERENT page than `ingestURL` will hand
    /// downstream — i.e. an offline handler unwrapped it. Surfaces that captured
    /// the on-screen HTML for `string` (the Safari "Read in Luna" hand-off, the
    /// action extension's article snapshot) must discard that capture when this is
    /// true: the bytes belong to the wrapper page (a publisher's subscribe
    /// interstitial is the live case — its HTML is the subscription pitch), not to
    /// the article being saved. Tracking-param stripping alone is NOT a different
    /// page, so a `?utm_…` article keeps its capture.
    public static func unwrapsToDifferentPage(_ string: String) -> Bool {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return unwrapOffline(url).didUnwrap
    }

    /// String convenience for input gates that hold a raw string. Returns the
    /// unwrapped target's string when an offline handler fires, else the original
    /// string unchanged (so a non-URL string is left for the caller's own gate).
    public static func unwrapOffline(_ string: String) -> String {
        guard let url = URL(string: string) else { return string }
        let result = unwrapOffline(url)
        return result.didUnwrap ? result.url.absoluteString : string
    }

    // MARK: - Result assembly

    /// Builds a result for a handler hit, stripping tracking params from the target
    /// so dedupe / display / share all see one canonical URL.
    private static func result(unwrapped target: URL) -> UnwrapResult {
        UnwrapResult(url: URLCanonicalizer.strip(target), didUnwrap: true)
    }

    /// Builds a result for a non-wrapper URL: the original URL, also
    /// tracking-stripped so every surface agrees on the canonical form.
    private static func result(unchanged url: URL) -> UnwrapResult {
        UnwrapResult(url: URLCanonicalizer.strip(url), didUnwrap: false)
    }

    // MARK: - Shortener host set

    /// Link shorteners / aggregators that wrap an article behind a plain HTTP
    /// redirect. News-relevant set — deliberately NOT a generic "follow every link".
    /// Several (`nyti.ms`, `wapo.st`, `on.ft.com`, `econ.st`) resolve to hard-paywall
    /// hosts, which then route to the archive reader.
    static let redirectShortenerHosts: Set<String> = [
        "flip.it", "trib.al", "t.co", "bit.ly", "buff.ly", "apple.co",
        "nyti.ms", "wapo.st", "on.ft.com", "econ.st", "reut.rs",
        "cnn.it", "bbc.in", "nbcnews.to", "abcn.ws", "cbsn.ws",
        // Bloomberg newsletter links make two ordinary HTTP hops: Iterable's
        // `links.message.bloomberg.com` tracking host → `bloom.bg` → publisher.
        // Treat both as redirect-only so the stored URL is the publisher article.
        "links.message.bloomberg.com", "bloom.bg",
    ]

    /// Amazon-issued share links are redirects, not storefronts. Keep them separate
    /// from `AmazonPriceRule.storefronts`: a product tracker must persist the final
    /// regional Amazon URL so its price and currency can be extracted correctly.
    /// `amzn.asia` is generated by Amazon's mobile sharing flow in Asia-Pacific;
    /// `a.co`, `amzn.to`, `amzn.eu`, `amzn.in`, and `amzn.com` are the other
    /// Amazon-owned short-link domains seen across its storefronts.
    static let amazonShortLinkHosts: Set<String> = [
        "a.co", "amzn.to", "amzn.eu", "amzn.asia", "amzn.in", "amzn.com",
    ]
}

// MARK: - Handler factories
//
// Each factory wraps the existing pure parsers on `NewsAggregatorUnwrapper`
// (`facebookRedirectTarget`, `googleNewsArticleID`, `googleNewsURL`,
// `appleNewsPublisherURL`, `googleBatchExecuteURL`) into a `WrapperHandler`
// for the registry.

public extension WrapperHandler {

    /// Facebook deep links (`fbrpc://…&target_url=…`) and `/l.php` link shims —
    /// both carry the target inline (offline). An `fbrpc://` link has no http host,
    /// so the matcher keys on scheme too.
    static let facebook = WrapperHandler(
        matches: { scheme, host in
            if scheme == "fbrpc" { return true }
            guard scheme == "https" || scheme == "http", let host else { return false }
            return host == "l.facebook.com" || host == "lm.facebook.com"
                || host == "m.facebook.com" || host == "facebook.com" || host == "www.facebook.com"
        },
        resolve: { url in .immediate(NewsAggregatorUnwrapper.facebookRedirectTarget(url)) })

    /// Google News (`news.google.com` / `news.url.google.com`). Classic `CBMi…` ids
    /// decode to the publisher URL offline (`.immediate`); new-style ids need the
    /// batchexecute round-trip — so the resolution is `.immediate` when the offline
    /// decode succeeds and `.fetch` otherwise. Expressed as `.fetch` whose closure
    /// first tries the offline decode, with a synchronous `.immediate` shortcut so
    /// `unwrapOffline` resolves classic links without going async.
    static let googleNews = WrapperHandler(
        matches: { _, host in host == "news.google.com" || host == "news.url.google.com" },
        resolve: { url in
            guard let articleID = NewsAggregatorUnwrapper.googleNewsArticleID(from: url) else {
                return .immediate(nil)
            }
            // Classic ids embed the publisher URL — resolvable offline.
            if let offline = NewsAggregatorUnwrapper.googleNewsURL(fromArticleID: articleID) {
                return .immediate(offline)
            }
            // New-style ids need the network round-trip.
            return .fetch { session in
                await NewsAggregatorUnwrapper.googleNewsBatchExecute(articleID: articleID, session: session)
            }
        })

    /// Apple News (`apple.news`, `*.apple.news`) and Apple Stocks article links
    /// (`stocks.apple.com`) — fetch the page and read the publisher URL from its
    /// `redirectToUrlAfterTimeout(...)` call. The apparent delay is browser-only;
    /// the target is already present in the initial HTML response.
    static let appleNews = WrapperHandler(
        matches: { _, host in
            guard let host else { return false }
            return NewsAggregatorUnwrapper.isAppleNews(host)
        },
        resolve: { url in
            .fetch { session in
                guard let html = await NewsAggregatorUnwrapper.fetchText(url, session: session) else { return nil }
                return NewsAggregatorUnwrapper.appleNewsPublisherURL(inHTML: html)
            }
        })

    /// Google share links (`share.google/<id>`) — Google's server-side share
    /// shortener. It 302s to an on-Google interstitial that only redirects onward to
    /// the real destination on a full GET (a HEAD stops one hop short), so this
    /// follows the chain with a GET rather than the HEAD-first shortener resolver. The
    /// destination can be anything Google shares — most relevantly a Google Shopping
    /// product page (`…/search?ibp=oshop&…&prds=…`), which then classifies as a
    /// product. Matches the host generically (any `share.google` link), never a
    /// specific id.
    static let googleShare = WrapperHandler(
        matches: { _, host in
            guard let host else { return false }
            return HostMatching.hostSuffixMatches(host, "share.google")
        },
        resolve: { url in
            .fetch { session in
                await NewsAggregatorUnwrapper.resolveFinalRedirectViaGET(url, session: session)
            }
        })

    /// Publisher subscribe / sign-in / cookie-check interstitials that carry the
    /// real page in a `dest=`-style query param (News Corp's
    /// `…/subscribe/news/1/?dest=<article>` and friends) — resolvable offline. The
    /// interstitial sits on the publisher's OWN host, so unlike every other handler
    /// this one can't be identified by host: the matcher accepts any http(s) URL and
    /// `interstitialTarget` does the real (path + same-site) gating, returning nil
    /// for the overwhelming majority of URLs. Registered LAST for that reason — see
    /// `URLUnwrapper.handlers`.
    static let interstitial = WrapperHandler(
        matches: { scheme, _ in scheme == "https" || scheme == "http" },
        resolve: { url in .immediate(NewsAggregatorUnwrapper.interstitialTarget(url)) })

    /// Link shorteners — follow HTTP redirects (HEAD) and return the final URL only
    /// if it left the shortener's host.
    static func shorteners(_ hosts: Set<String>) -> WrapperHandler {
        WrapperHandler(
            matches: { _, host in
                guard let host else { return false }
                return HostMatching.hostSuffixMatches(host, anyOf: hosts)
            },
            resolve: { url in
                .fetch { session in await NewsAggregatorUnwrapper.resolveFinalRedirect(url, session: session) }
            })
    }
}

//
//  BypassPlan.swift
//  ReaderKit
//

import LunaModels
import Foundation

/// A bypass strategy that runs in the background URLSession path — provably silent
/// (no WKWebView). Split out of `BypassStrategy` so a caller can never need to filter
/// out the non-silent cases: a `SilentStrategy` is silent by construction.
public enum SilentStrategy: Equatable {
    case jsonLDBody
    case userAgent(CrawlerAgent)
    case referer(RefererOrigin)
    case trailingDotHost
    case freshSession
    case amp
    case ampQuery
    case waybackRaw
    case waybackPrePaywall
    case jinaReader
    case ladderProxy(LadderProxy)

    /// The wider `BypassStrategy` this silent case corresponds to (for the runner and
    /// diagnostics, which still speak `BypassStrategy`).
    public var asBypassStrategy: BypassStrategy {
        switch self {
        case .jsonLDBody: return .jsonLDBody
        case let .userAgent(agent): return .userAgent(agent)
        case let .referer(origin): return .referer(origin)
        case .trailingDotHost: return .trailingDotHost
        case .freshSession: return .freshSession
        case .amp: return .amp
        case .ampQuery: return .ampQuery
        case .waybackRaw: return .waybackRaw
        case .waybackPrePaywall: return .waybackPrePaywall
        case .jinaReader: return .jinaReader
        case let .ladderProxy(proxy): return .ladderProxy(proxy)
        }
    }
}

/// A bypass strategy that needs a real WKWebView (client-side JS render). archive.today
/// is modeled separately as the terminal flow (`BypassPlan.allowsArchiveToday`), so a
/// `WebStrategy` is always a non-terminal pre-stage.
public enum WebStrategy: Equatable {
    /// Load the original URL in the WKWebView with paywall scripts blocked
    /// plus a DOM-cleanup userscript (the core direct-unlock technique). The
    /// reader's pre-stage flow installs the content rules and cleanup before
    /// loading it.
    case directUnlock
    /// The trailing-dot FQDN variant, loaded in a real browser. Emitted
    /// whenever the selector chose trailing-dot, including when the silent
    /// fetch already tried it: the trick is a client-side origin behaviour
    /// that only takes effect in a browser, so the WKWebView attempt can
    /// succeed where the silent URLSession fetch could not.
    case trailingDotHost
}

/// One typed, ordered bypass plan, built once by `make(for:directHTML:)` and
/// consumed by both the background resolver (the `silent` leg) and the
/// archive web reader (the `webPreStages` leg plus `allowsArchiveToday`).
/// Because both paths read the same plan from the same factory, they cannot
/// derive divergent strategy orderings.
public struct BypassPlan: Equatable {
    /// Ordered URLSession strategies for the background path — provably silent.
    public let silent: [SilentStrategy]
    /// Ordered WKWebView pre-stage strategies (archive.today excluded) — the
    /// browser-only tricks (currently the trailing-dot origin variant) tried before
    /// the terminal archive flow.
    public let webPreStages: [WebStrategy]
    /// Whether the archive.today terminal WKWebView flow is permitted at the end.
    public let allowsArchiveToday: Bool

    /// Aggregate budget for the resolver's silent chain. Each individual silent fetch
    /// is already capped (~12–30s), but a host with several silent strategies could
    /// serially burn ~a minute before parking; this bounds the whole leg so the ingest
    /// path fails fast to `.needsArchive` instead of blocking.
    public static let silentChainDeadlineSeconds: TimeInterval = 20

    /// The same budget when the resolver already holds a readable browser
    /// capture (the Safari "Read in Luna" hand-off of a page whose body the
    /// server truncated). The chain is then only trying to improve on
    /// something the user can already read, so it gets a fraction of the
    /// time before we hand that capture back.
    public static let trustedCaptureSilentDeadlineSeconds: TimeInterval = 8

    /// Builds the plan for `url` from the existing pure selector. Pure — no
    /// I/O. The selector still owns gate, per-host-rule, generic-fallback,
    /// and normalization; this factory just splits its single ordered
    /// `[BypassStrategy]` into the typed legs so the two consumers cannot
    /// diverge.
    ///
    /// - `silent` = the silent prefix, in order.
    /// - `webPreStages` = the WKWebView (non-archive) strategies; trailing-dot is kept
    ///   here even if it ran silently, because the trick only takes effect in a real
    ///   browser (the silent fetch sees the same wall).
    /// - `allowsArchiveToday` = whether `.archiveToday` is in the selected list.
    ///
    /// `directFailure` carries why the direct read failed, when it did. It
    /// is what makes a browser pre-stage reachable on a host with no unlock
    /// rule: a 401/403/429 refusal is a verdict on the client, and a
    /// WKWebView is a different client (`SaveFailureReason.browserMayRecover`).
    public static func make(
        for url: URL, directHTML: String?, directFailure: SaveFailureReason? = nil,
        silentTierExhausted: Bool = false
    ) -> BypassPlan {
        let strategies = BypassStrategySelector.strategies(
            for: url, directHTML: directHTML, directFailure: directFailure,
            silentTierExhausted: silentTierExhausted)

        let silent: [SilentStrategy] = strategies.compactMap(Self.silentStrategy)

        let webPreStages: [WebStrategy] = strategies.compactMap { strategy -> WebStrategy? in
            switch strategy {
            case .directUnlock:
                return .directUnlock
            case .trailingDotHost:
                // The trailing-dot trick is a client-side origin behaviour,
                // not a server one: a real browser scopes the meter's
                // host-keyed cookies/JS to `www.example.com` and treats
                // `www.example.com.` as a different origin, so the article
                // renders, whereas the silent URLSession fetch just gets the
                // same gated server HTML. So it is always worth a WKWebView
                // pre-stage, even (especially) when the silent fetch already
                // tried and failed: the web pre-stages only run once silent
                // bypass has been exhausted and the item parked, so the
                // browser attempt is the whole point of trying it here
                // before falling back to archive.today.
                return .trailingDotHost
            default:
                return nil
            }
        }

        return BypassPlan(
            silent: silent,
            webPreStages: webPreStages,
            allowsArchiveToday: strategies.contains(.archiveToday))
    }

    /// Maps a `BypassStrategy` to its `SilentStrategy` case, or nil for archive.is.
    private static func silentStrategy(_ strategy: BypassStrategy) -> SilentStrategy? {
        switch strategy {
        case .jsonLDBody: return .jsonLDBody
        case let .userAgent(agent): return .userAgent(agent)
        case let .referer(origin): return .referer(origin)
        case .trailingDotHost: return .trailingDotHost
        case .freshSession: return .freshSession
        case .amp: return .amp
        case .ampQuery: return .ampQuery
        case .waybackRaw: return .waybackRaw
        case .waybackPrePaywall: return .waybackPrePaywall
        case .jinaReader: return .jinaReader
        case let .ladderProxy(proxy): return .ladderProxy(proxy)
        case .directUnlock, .archiveToday: return nil
        }
    }
}

/// The one strategy→URL mapper, replacing the duplicated `switch strategy`
/// URL builders that lived in `BypassRunner.run` and
/// `ArchiveWebReaderViewController.webPreStageURLs`.
public enum BypassURLs {

    /// The URL a silent strategy fetches over URLSession, or nil when it can't be
    /// formed / the strategy is zero-network (`.jsonLDBody`) or AMP-discovered (`.amp`,
    /// which needs the direct HTML — unlike `.ampQuery`, which derives the AMP URL from
    /// the article URL alone). `freshSession`/`userAgent`/`referer`/`waybackRaw`/
    /// `jinaReader` fetch the canonical `article` URL itself (the request transform is
    /// the header/session, not the URL), so they return `article`.
    public static func requestURL(for strategy: SilentStrategy, article: URL) -> URL? {
        switch strategy {
        case .jsonLDBody, .amp:
            return nil
        case .ampQuery:
            return AMPQueryBypass.ampQueryURL(for: article)
        case .trailingDotHost:
            return TrailingDotBypass.trailingDotURL(for: article)
        case let .ladderProxy(proxy):
            return proxy.url(for: article)
        case .userAgent, .referer, .freshSession, .waybackRaw, .waybackPrePaywall, .jinaReader:
            return article
        }
    }

    /// The URL a WKWebView pre-stage loads, or nil when it can't be formed.
    public static func loadURL(for strategy: WebStrategy, article: URL) -> URL? {
        switch strategy {
        case .directUnlock:
            // The original article URL — the reader applies the content rules +
            // cleanup before loading it.
            return article
        case .trailingDotHost:
            return TrailingDotBypass.trailingDotURL(for: article)
        }
    }
}

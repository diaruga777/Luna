//
//  BypassPlan.swift
//  ReaderKit
//

import Foundation

/// A bypass strategy that runs in the background URLSession path — provably silent
/// (no WKWebView). Split out of `BypassStrategy` so the "skip the non-silent cases"
/// filter the resolver used to apply is no longer representable: a `SilentStrategy`
/// is silent by construction.
enum SilentStrategy: Equatable {
    case jsonLDBody
    case userAgent(CrawlerAgent)
    case referer(RefererOrigin)
    case trailingDotHost
    case freshSession
    case amp
    case waybackRaw
    case jinaReader
    case ladderProxy(LadderProxy)

    /// The wider `BypassStrategy` this silent case corresponds to (for the runner and
    /// diagnostics, which still speak `BypassStrategy`).
    var asBypassStrategy: BypassStrategy {
        switch self {
        case .jsonLDBody: return .jsonLDBody
        case let .userAgent(agent): return .userAgent(agent)
        case let .referer(origin): return .referer(origin)
        case .trailingDotHost: return .trailingDotHost
        case .freshSession: return .freshSession
        case .amp: return .amp
        case .waybackRaw: return .waybackRaw
        case .jinaReader: return .jinaReader
        case let .ladderProxy(proxy): return .ladderProxy(proxy)
        }
    }

    /// Whether repeating this strategy in a WKWebView pre-stage can succeed where the
    /// silent fetch failed. A pure origin/URL trick like trailing-dot returns the same
    /// wall in a browser, so it is NOT repeated as a ~9s pre-stage (the NYT slowness);
    /// only client-rendered services benefit from a real JS render (handled by the web
    /// leg). All silent strategies are URLSession transforms, so none benefit here.
    var benefitsFromJSRetry: Bool { false }
}

/// A bypass strategy that needs a real WKWebView (client-side JS render). archive.today
/// is modeled separately as the terminal flow (`BypassPlan.allowsArchiveToday`), so a
/// `WebStrategy` is always a non-terminal pre-stage.
enum WebStrategy: Equatable {
    /// The trailing-dot FQDN variant, loaded in a browser. ONLY emitted when it didn't
    /// already run as a silent strategy — `benefitsFromJSRetry` is false (a pure origin
    /// trick), so the plan factory never repeats it as a pre-stage when it was silent.
    case trailingDotHost
    case thirdPartyWeb(ThirdPartyWebService)

    var asBypassStrategy: BypassStrategy {
        switch self {
        case .trailingDotHost: return .trailingDotHost
        case let .thirdPartyWeb(service): return .thirdPartyWeb(service)
        }
    }

    /// Only client-rendered services gain from a JS render on retry. A trailing-dot
    /// origin trick returns the same wall, so it is never repeated as a pre-stage.
    var benefitsFromJSRetry: Bool {
        if case .thirdPartyWeb = self { return true }
        return false
    }
}

/// ONE typed, ordered bypass plan, built ONCE by `make(for:directHTML:)` and consumed
/// by both the background resolver (the `silent` leg) and the archive web reader (the
/// `webPreStages` leg + `allowsArchiveToday`). Because both paths read the same plan
/// from the same factory, they can no longer derive divergent orderings (the former
/// double-compute between `ArticleResolver` and `webPreStageURLs`).
struct BypassPlan: Equatable {
    /// Ordered URLSession strategies for the background path — provably silent.
    let silent: [SilentStrategy]
    /// Ordered WKWebView pre-stage strategies (archive.today excluded). Only strategies
    /// that `benefitsFromJSRetry`, plus a trailing-dot that was NOT already tried
    /// silently, appear here.
    let webPreStages: [WebStrategy]
    /// Whether the archive.today terminal WKWebView flow is permitted at the end.
    let allowsArchiveToday: Bool

    /// Aggregate budget for the resolver's silent chain. Each individual silent fetch
    /// is already capped (~12–30s), but a host with several silent strategies could
    /// serially burn ~a minute before parking; this bounds the whole leg so the ingest
    /// path fails fast to `.needsArchive` instead of blocking.
    static let silentChainDeadlineSeconds: TimeInterval = 20

    /// Build the plan for `url` from the existing pure selector. PURE — no I/O. The
    /// selector still owns gate + per-host-rule + generic-fallback + normalization;
    /// this factory just splits its single ordered `[BypassStrategy]` into the typed
    /// legs so the two consumers can't diverge.
    ///
    /// - `silent` = the silent prefix, in order.
    /// - `webPreStages` = the WKWebView (non-archive) strategies, minus any trailing-dot
    ///   that already ran silently (it doesn't benefit from a JS retry — the NYT
    ///   redundant-pre-stage fix).
    /// - `allowsArchiveToday` = whether `.archiveToday` is in the selected list.
    static func make(for url: URL, directHTML: String?) -> BypassPlan {
        let strategies = BypassStrategySelector.strategies(for: url, directHTML: directHTML)

        let silent: [SilentStrategy] = strategies.compactMap(Self.silentStrategy)
        let triedTrailingDotSilently = silent.contains(.trailingDotHost)

        let webPreStages: [WebStrategy] = strategies.compactMap { strategy -> WebStrategy? in
            switch strategy {
            case .trailingDotHost:
                // A trailing-dot rewrite returns the same wall in a browser, so it is
                // only worth a pre-stage when it has NOT already run silently.
                return triedTrailingDotSilently ? nil : .trailingDotHost
            case let .thirdPartyWeb(service):
                return .thirdPartyWeb(service)
            default:
                return nil
            }
        }

        return BypassPlan(
            silent: silent,
            webPreStages: webPreStages,
            allowsArchiveToday: strategies.contains(.archiveToday))
    }

    /// Maps a `BypassStrategy` to its `SilentStrategy` case, or nil for the WKWebView
    /// strategies (`.thirdPartyWeb`, `.archiveToday`).
    private static func silentStrategy(_ strategy: BypassStrategy) -> SilentStrategy? {
        switch strategy {
        case .jsonLDBody: return .jsonLDBody
        case let .userAgent(agent): return .userAgent(agent)
        case let .referer(origin): return .referer(origin)
        case .trailingDotHost: return .trailingDotHost
        case .freshSession: return .freshSession
        case .amp: return .amp
        case .waybackRaw: return .waybackRaw
        case .jinaReader: return .jinaReader
        case let .ladderProxy(proxy): return .ladderProxy(proxy)
        case .thirdPartyWeb, .archiveToday: return nil
        }
    }
}

/// The ONE strategy→URL mapper, replacing the duplicated `switch strategy` URL builders
/// that lived in `BypassRunner.run` and `ArchiveWebReaderViewController.webPreStageURLs`.
enum BypassURLs {

    /// The URL a silent strategy fetches over URLSession, or nil when it can't be
    /// formed / the strategy is zero-network (`.jsonLDBody`) or AMP-discovered (`.amp`,
    /// which needs the direct HTML). `freshSession`/`userAgent`/`referer`/`waybackRaw`/
    /// `jinaReader` fetch the canonical `article` URL itself (the request transform is
    /// the header/session, not the URL), so they return `article`.
    static func requestURL(for strategy: SilentStrategy, article: URL) -> URL? {
        switch strategy {
        case .jsonLDBody, .amp:
            return nil
        case .trailingDotHost:
            return TrailingDotBypass.trailingDotURL(for: article)
        case let .ladderProxy(proxy):
            return proxy.url(for: article)
        case .userAgent, .referer, .freshSession, .waybackRaw, .jinaReader:
            return article
        }
    }

    /// The URL a WKWebView pre-stage loads, or nil when it can't be formed.
    static func loadURL(for strategy: WebStrategy, article: URL) -> URL? {
        switch strategy {
        case .trailingDotHost:
            return TrailingDotBypass.trailingDotURL(for: article)
        case let .thirdPartyWeb(service):
            return service.url(for: article)
        }
    }
}

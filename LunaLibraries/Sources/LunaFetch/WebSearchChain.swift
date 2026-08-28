//
//  WebSearchChain.swift
//  LunaFetch
//

import Foundation

/// One keyless web-search provider, as the chain sees it.
///
/// A protocol rather than a closure because the chain's ORDER is the behaviour
/// worth pinning, and a test has to be able to answer for each leg
/// independently.
public protocol WebSearchProviding: Sendable {
    func search(query: String) async -> WebSearchProviderOutcome
}

/// What one provider answered. `rateLimited` exists because it is the only
/// answer that changes what the chain does NEXT time.
public enum WebSearchProviderOutcome: Equatable, Sendable {
    case results([URL])
    case rateLimited(retryAfter: TimeInterval?)
    case unavailable
}

/// Which provider's answer the caller is holding.
public enum WebSearchProvider: String, Sendable {
    case firecrawl
    case duckDuckGo
}

/// What became of the Firecrawl leg on one run — the part of a chain run that
/// is otherwise invisible, since the caller only ever sees URLs.
public enum FirecrawlSearchLeg: Equatable, Sendable {
    /// The device is still inside a cooldown, so Firecrawl was not asked.
    case cooling(remaining: TimeInterval)
    case served(count: Int)
    /// Refused, with the cooldown that refusal bought.
    case rateLimited(cooldown: TimeInterval)
    case unavailable
    /// A successful search that found nothing.
    case empty
}

/// One chain run: the URLs, who served them, and what the Firecrawl leg did.
public struct WebSearchChainOutcome: Equatable, Sendable {
    /// Rank-ordered result URLs. Nil means BOTH providers failed — the same
    /// "no search happened" the fan-out's Layer 2 reads as "skip me", as
    /// distinct from an empty array's "searched, found nothing".
    public let urls: [URL]?
    public let servedBy: WebSearchProvider?
    public let firecrawl: FirecrawlSearchLeg

    public init(urls: [URL]?, servedBy: WebSearchProvider?, firecrawl: FirecrawlSearchLeg) {
        self.urls = urls
        self.servedBy = servedBy
        self.firecrawl = firecrawl
    }

    /// One diagnostic line, in the fan-out's `key=value` house style. The
    /// formatting lives on the value so every caller says the same thing.
    public var logLine: String {
        [
            "web-search",
            "firecrawl=\(firecrawlDescription)",
            "served=\(servedBy?.rawValue ?? "none")",
            "results=\(urls?.count ?? 0)",
        ].joined(separator: " ")
    }

    private var firecrawlDescription: String {
        switch firecrawl {
        case let .cooling(remaining): return "cooling(\(Int(remaining.rounded()))s)"
        case .served: return "served"
        case let .rateLimited(cooldown): return "ratelimited(cooldown=\(Int(cooldown.rounded()))s)"
        case .unavailable: return "unavailable"
        case .empty: return "empty"
        }
    }
}

/// Firecrawl first, DuckDuckGo second — the fan-out's Layer-2 search
/// (`claudedocs/price-comparison.md`).
///
/// Firecrawl leads because it answers structured JSON: no results-page markup to
/// drift, and no bot challenge to tell apart from an empty page. DuckDuckGo
/// stays because Firecrawl's keyless budget is per IP and finite, and a save
/// that lands after the daily cap still deserves a Layer 2.
public enum WebSearchChain {

    /// Rank-ordered result URLs, with `DuckDuckGoSearch.results`' semantics:
    /// nil when no search produced an answer at all.
    public static func results(forQuery query: String) async -> [URL]? {
        await search(forQuery: query).urls
    }

    /// The same search, keeping which provider served it — for the caller that
    /// logs the run.
    public static func search(
        forQuery query: String,
        firecrawl: any WebSearchProviding = FirecrawlWebSearchProvider(),
        duckDuckGo: any WebSearchProviding = DuckDuckGoWebSearchProvider(),
        cooldown: FirecrawlSearchCooldown = .shared
    ) async -> WebSearchChainOutcome {
        let report: FirecrawlSearchLeg
        switch await firecrawlLeg(query: query, provider: firecrawl, cooldown: cooldown) {
        case let .servedURLs(urls):
            return WebSearchChainOutcome(
                urls: urls, servedBy: .firecrawl, firecrawl: .served(count: urls.count))
        case let .fellThrough(leg):
            report = leg
        }
        guard case let .results(urls) = await duckDuckGo.search(query: query) else {
            // Firecrawl's own empty answer is a search that happened, so it
            // stands as an empty result rather than becoming "no search".
            return WebSearchChainOutcome(
                urls: report == .empty ? [] : nil, servedBy: nil, firecrawl: report)
        }
        return WebSearchChainOutcome(urls: urls, servedBy: .duckDuckGo, firecrawl: report)
    }

    /// The Firecrawl leg's two shapes: it served usable URLs, or the chain must
    /// go on to DuckDuckGo carrying what happened.
    private enum FirecrawlLeg {
        case servedURLs([URL])
        case fellThrough(FirecrawlSearchLeg)
    }

    private static func firecrawlLeg(
        query: String, provider: any WebSearchProviding, cooldown: FirecrawlSearchCooldown
    ) async -> FirecrawlLeg {
        if let remaining = cooldown.remaining() {
            return .fellThrough(.cooling(remaining: remaining))
        }
        switch await provider.search(query: query) {
        case let .results(urls) where !urls.isEmpty:
            cooldown.recordSuccess()
            return .servedURLs(urls)
        case .results:
            cooldown.recordSuccess()
            return .fellThrough(.empty)
        case let .rateLimited(retryAfter):
            let wait = cooldown.recordRateLimit(retryAfter: retryAfter)
            return .fellThrough(.rateLimited(cooldown: wait))
        case .unavailable:
            return .fellThrough(.unavailable)
        }
    }
}

/// `FirecrawlSearch` as the chain's first leg.
public struct FirecrawlWebSearchProvider: WebSearchProviding {

    /// Biases results to a market, when the caller knows one.
    private let location: String?

    public init(location: String? = nil) {
        self.location = location
    }

    public func search(query: String) async -> WebSearchProviderOutcome {
        switch await FirecrawlSearch.results(forQuery: query, location: location) {
        case let .results(entries): return .results(entries.map(\.url))
        case let .rateLimited(retryAfter): return .rateLimited(retryAfter: retryAfter)
        case .unavailable: return .unavailable
        }
    }
}

/// `DuckDuckGoSearch` as the chain's fallback leg. It has no rate-limit answer
/// of its own: its challenge page is already folded into a nil result.
public struct DuckDuckGoWebSearchProvider: WebSearchProviding {
    public init() {}

    public func search(query: String) async -> WebSearchProviderOutcome {
        guard let urls = await DuckDuckGoSearch.results(forQuery: query) else {
            return .unavailable
        }
        return .results(urls)
    }
}

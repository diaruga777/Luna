//
//  BypassRunner.swift
//  ReaderKit
//

import LunaFetch
import LunaHTMLClassification
import LunaModels
import Foundation

/// Runs a single silent `BypassStrategy` (a URLSession request transform) and
/// returns the fetched and extracted content paired with its source HTML, or
/// nil when the strategy is not applicable, did not fetch, or did not parse.
/// The only new I/O unit in the pipeline — protocol-ized so callers can mock
/// it, and itself driven by the `HTMLFetching` protocol so it is testable
/// without the network.
///
/// `.directUnlock` and `.archiveToday` are not silent; `run` returns nil for both
/// (the archive web reader handles them instead).
public protocol BypassRunning {
    /// Runs `strategy` for `url`. `directHTML` is the already-fetched direct page,
    /// reused by zero-network strategies (`.jsonLDBody`) and AMP discovery. Returns
    /// the extracted content + winning source HTML, or nil.
    func run(
        _ strategy: BypassStrategy, url: URL, directHTML: String?
    ) async -> ExtractedArticle?
}

/// The live `BypassRunning` implementation: maps each silent strategy to the
/// concrete `HTMLFetching` call via the shared `BypassURLs` mapper, then extracts
/// through the shared `ArticleExtraction.fetchAndExtract` helper.
public struct BypassRunner: BypassRunning {
    public let fetcher: HTMLFetching
    public let extraction: ArticleExtraction

    public init(fetcher: HTMLFetching = ArticleFetcher(), extractor: ArticleExtractor = ArticleExtractor()) {
        self.fetcher = fetcher
        self.extraction = ArticleExtraction(extractor: extractor)
    }

    /// Runs the strategy and records the attempt. "Which strategies were tried,
    /// and what did each get" is the single most useful thing a failed save's
    /// trace can say, so every attempt reports through `BypassAttempt` — the
    /// same value-with-a-`logLine` shape the seller fan-out uses
    /// (`SellerFanOutAttempt`, `claudedocs/price-comparison.md`).
    public func run(
        _ strategy: BypassStrategy, url: URL, directHTML: String?
    ) async -> ExtractedArticle? {
        let started = Date()
        let article = await perform(strategy, url: url, directHTML: directHTML)
        SaveDiagnostics.record(
            BypassAttempt(
                strategy: strategy,
                extractedCharacters: article?.content.bodyTextLength,
                readable: article.map(ArticleExtraction.isReadableArticle) ?? false,
                elapsedMilliseconds: Int(Date().timeIntervalSince(started) * 1000)
            ).logLine,
            category: "bypass")
        return article
    }

    private func perform(
        _ strategy: BypassStrategy, url: URL, directHTML: String?
    ) async -> ExtractedArticle? {
        switch strategy {
        case .jsonLDBody:
            // Zero network: re-parse the HTML we already have, forcing the JSON-LD
            // articleBody layer even if the rendered DOM looked paywalled.
            guard let directHTML,
                  let content = extraction.extractFromJSONLD(html: directHTML, baseURL: url)
            else { return nil }
            return ExtractedArticle(content: content, sourceHTML: directHTML)

        case let .userAgent(agent):
            return await extraction.fetchAndExtract(baseURL: url) {
                try await fetcher.fetchHTML(from: url, userAgent: agent.userAgent,
                                            xForwardedFor: agent.xForwardedFor)
            }

        case let .referer(origin):
            return await extraction.fetchAndExtract(baseURL: url) {
                try await fetcher.fetchHTML(from: url, referer: origin.url)
            }

        case .trailingDotHost:
            guard let dotted = BypassURLs.requestURL(for: .trailingDotHost, article: url) else { return nil }
            // The base URL stays the canonical (no-dot) URL so extracted links resolve
            // against the real host, not the dotted variant.
            return await extraction.fetchAndExtract(baseURL: url) {
                try await fetcher.fetchHTML(from: dotted)
            }

        case .freshSession:
            return await extraction.fetchAndExtract(baseURL: url) {
                try await fetcher.fetchHTMLWithoutCookies(from: url)
            }

        case .amp:
            guard let directHTML, let ampURL = ArticleResolver.ampURL(in: directHTML, base: url)
            else { return nil }
            return await extraction.fetchAndExtract(baseURL: ampURL) {
                try await fetcher.fetchHTML(from: ampURL)
            }

        case .ampQuery:
            guard let ampURL = BypassURLs.requestURL(for: .ampQuery, article: url) else { return nil }
            // The base URL stays the AMP document's own URL so its relative links and
            // images resolve; it's the same origin and path as the article. The
            // document is normalized first (subscriber gate stripped, `amp-img`
            // rewritten to `img`) — an AMP document carries the pitch alongside the
            // body, and its gate wording would otherwise make the extractor reject the
            // very article it holds.
            return await extraction.fetchAndExtract(baseURL: ampURL) {
                AMPQueryBypass.extractableHTML(from: try await fetcher.fetchHTML(from: ampURL))
            }

        case .waybackRaw:
            return await extraction.fetchAndExtract(baseURL: url) {
                try await fetcher.fetchWaybackRawHTML(for: url)
            }

        case .waybackPrePaywall:
            return await extraction.fetchAndExtract(baseURL: url) {
                try await fetcher.fetchWaybackPrePaywallHTML(for: url)
            }

        case .jinaReader:
            return await extraction.fetchAndExtract(baseURL: url) {
                try await fetcher.fetchJinaReader(for: url)
            }

        case let .ladderProxy(proxy):
            guard let proxyURL = BypassURLs.requestURL(for: .ladderProxy(proxy), article: url) else { return nil }
            return await extraction.fetchAndExtract(baseURL: url) {
                try await fetcher.fetchHTML(from: proxyURL)
            }

        case .directUnlock, .archiveToday:
            // WKWebView-only — handled by ArchiveWebReaderViewController, not here.
            return nil
        }
    }
}

/// One silent bypass attempt, as a value that knows how to describe itself —
/// so the trace line and the thing it describes can't drift.
struct BypassAttempt {
    let strategy: BypassStrategy
    /// Body characters the attempt extracted, or nil when it produced nothing
    /// (inapplicable, fetch failed, or unparseable).
    let extractedCharacters: Int?
    /// Whether what it extracted actually cleared the readable-vs-stub gate —
    /// an attempt can extract 400 characters of paywall pitch and still lose.
    let readable: Bool
    let elapsedMilliseconds: Int

    var logLine: String {
        let outcome = extractedCharacters.map {
            "extracted \($0)ch, \(readable ? "readable" : "not readable")"
        } ?? "no result"
        return "strategy \(strategy): \(outcome) in \(elapsedMilliseconds)ms"
    }
}

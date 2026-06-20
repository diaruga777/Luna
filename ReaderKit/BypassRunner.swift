//
//  BypassRunner.swift
//  ReaderKit
//

import Foundation

/// Runs a single SILENT `BypassStrategy` (a URLSession request transform) and returns
/// the fetched+extracted content paired with its source HTML, or nil when the
/// strategy isn't applicable / didn't fetch / didn't parse. The only new I/O unit in
/// the pipeline — protocol-ized so callers can mock it, and itself driven by the
/// `HTMLFetching` protocol so it's testable without the network.
///
/// WKWebView-only strategies (`.thirdPartyWeb`, `.archiveToday`) are not silent;
/// `run` returns nil for them (they're handled by the archive web reader).
protocol BypassRunning {
    /// Runs `strategy` for `url`. `directHTML` is the already-fetched direct page,
    /// reused by zero-network strategies (`.jsonLDBody`) and AMP discovery. Returns
    /// the extracted content + winning source HTML, or nil.
    func run(
        _ strategy: BypassStrategy, url: URL, directHTML: String?
    ) async -> (ArticleContent, String)?
}

/// The live `BypassRunning` implementation: maps each silent strategy to the
/// concrete `HTMLFetching` call, then extracts.
struct BypassRunner: BypassRunning {
    let fetcher: HTMLFetching
    let extractor: ArticleExtractor

    init(fetcher: HTMLFetching = ArticleFetcher(), extractor: ArticleExtractor = ArticleExtractor()) {
        self.fetcher = fetcher
        self.extractor = extractor
    }

    func run(
        _ strategy: BypassStrategy, url: URL, directHTML: String?
    ) async -> (ArticleContent, String)? {
        switch strategy {
        case .jsonLDBody:
            // Zero network: re-parse the HTML we already have, forcing the JSON-LD
            // articleBody layer even if the rendered DOM looked paywalled.
            guard let directHTML,
                  let content = extractor.extractFromJSONLD(html: directHTML, baseURL: url)
            else { return nil }
            return (content, directHTML)

        case let .userAgent(agent):
            return await extracted(baseURL: url) {
                try await fetcher.fetchHTML(from: url, userAgent: agent.userAgent,
                                            xForwardedFor: agent.xForwardedFor)
            }

        case let .referer(origin):
            return await extracted(baseURL: url) {
                try await fetcher.fetchHTML(from: url, referer: origin.url)
            }

        case .trailingDotHost:
            guard let dotted = TrailingDotBypass.trailingDotURL(for: url) else { return nil }
            // The base URL stays the canonical (no-dot) URL so extracted links resolve
            // against the real host, not the dotted variant.
            return await extracted(baseURL: url) {
                try await fetcher.fetchHTML(from: dotted)
            }

        case .freshSession:
            return await extracted(baseURL: url) {
                try await fetcher.fetchHTMLWithoutCookies(from: url)
            }

        case .amp:
            guard let directHTML, let ampURL = ArticleResolver.ampURL(in: directHTML, base: url)
            else { return nil }
            return await extracted(baseURL: ampURL) {
                try await fetcher.fetchHTML(from: ampURL)
            }

        case .waybackRaw:
            return await extracted(baseURL: url) {
                try await fetcher.fetchWaybackRawHTML(for: url)
            }

        case .jinaReader:
            return await extracted(baseURL: url) {
                try await fetcher.fetchJinaReader(for: url)
            }

        case let .ladderProxy(proxy):
            guard let proxyURL = proxy.url(for: url) else { return nil }
            return await extracted(baseURL: url) {
                try await fetcher.fetchHTML(from: proxyURL)
            }

        case .thirdPartyWeb, .archiveToday:
            // WKWebView-only — handled by ArchiveWebReaderViewController, not here.
            return nil
        }
    }

    /// Runs a fetch and extracts it, pairing content with its source HTML; nil on any
    /// fetch/parse failure (so a dead strategy falls through gracefully).
    private func extracted(
        baseURL: URL, fetch: () async throws -> String
    ) async -> (ArticleContent, String)? {
        guard let html = try? await fetch(),
              let content = try? extractor.extract(html: html, baseURL: baseURL)
        else { return nil }
        return (content, html)
    }
}

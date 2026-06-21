//
//  ArticleExtraction.swift
//  ReaderKit
//

import Foundation

/// Extracted content paired with the source HTML it came from — always present
/// together (the project's "two optionals that travel as one" rule). Lets the
/// readable predicate hang off the pair and gives the resolver a structural
/// `Equatable` instead of a hand-written tuple comparison.
struct ExtractedArticle: Equatable {
    let content: ArticleContent
    let sourceHTML: String
}

/// Stage-2 processing component: the ONE place that turns markup into structured
/// `ArticleContent` and judges whether that content is a readable article. Pure
/// core (`extract` / `extractFromJSONLD` delegate to `ArticleExtractor`) plus a
/// single bounded-I/O helper (`fetchAndExtract`) used by every fetch-then-extract
/// call site, so the duplicate helpers in `ArticleResolver` and `BypassRunner`
/// collapse into one.
///
/// Extraction NEVER knows that bypass exists; bypass only supplies candidate HTML.
struct ArticleExtraction {

    /// The pure HTML→blocks parser. Stateless, so a shared instance is fine.
    private let extractor: ArticleExtractor

    init(extractor: ArticleExtractor = ArticleExtractor()) {
        self.extractor = extractor
    }

    /// Parse `html` into structured content. Throws `ArticleExtractor.ExtractError`
    /// only when the document holds no usable text at all. Pure (no network).
    func extract(html: String, baseURL: URL) throws -> ArticleContent {
        try extractor.extract(html: html, baseURL: baseURL)
    }

    /// JSON-LD `articleBody`-only extraction, for the `.jsonLDBody` bypass strategy.
    /// Pure (parse only). Nil when the page carries no `articleBody`.
    func extractFromJSONLD(html: String, baseURL: URL) -> ArticleContent? {
        extractor.extractFromJSONLD(html: html, baseURL: baseURL)
    }

    /// THE single readable-vs-paywall-stub predicate. Consolidates the three former
    /// duplicate checks (`ArticleResolver.isReadable`, `BypassGate` step 3, and the
    /// implicit `!looksPaywalled` inside `ArticleContent.hasReadableBody`) into one
    /// well-tested, HTML-aware function: a body that clears the length threshold AND
    /// doesn't read as a paywall (including the publisher-declared schema.org lock the
    /// HTML carries). Pass `html` whenever the source HTML is available so the lock
    /// signal can't be bypassed by reaching for a text-only path. Pure.
    static func isReadableArticle(_ content: ArticleContent, html: String?) -> Bool {
        content.bodyTextLength >= ArticleContent.readableBodyThreshold
            && !PaywallDetector.looksPaywalled(content: content, html: html)
    }

    /// Whether a fetched+extracted pair is a readable article — the pair-shaped
    /// overload of `isReadableArticle` (the source HTML is always known here).
    static func isReadableArticle(_ article: ExtractedArticle) -> Bool {
        isReadableArticle(article.content, html: article.sourceHTML)
    }

    /// Runs an HTML fetch and extracts it, pairing the parsed content with its source
    /// HTML. Returns nil if the fetch or parse fails (so a dead source falls through
    /// gracefully). The ONE shared fetch-then-extract helper for the whole pipeline.
    func fetchAndExtract(
        baseURL: URL, fetch: () async throws -> String
    ) async -> ExtractedArticle? {
        guard let html = try? await fetch(),
              let content = try? extract(html: html, baseURL: baseURL)
        else { return nil }
        return ExtractedArticle(content: content, sourceHTML: html)
    }
}

//
//  ArticleExtraction.swift
//  Luna
//

import LunaModels
import Foundation

/// Extracted content paired with the source HTML it came from. The two always
/// travel together, so the readable predicate can hang off the pair and the
/// resolver gets a structural `Equatable` instead of a hand-written tuple
/// comparison.
public struct ExtractedArticle: Equatable {
    public let content: ArticleContent
    public let sourceHTML: String
    private let readability = MemoizedVerdict()

    public init(content: ArticleContent, sourceHTML: String) {
        self.content = content
        self.sourceHTML = sourceHTML
    }

    /// `ArticleExtraction.isReadableArticle`, remembered after the first ask.
    /// Both inputs are immutable, so the verdict cannot go stale, and it is
    /// asked for several times per candidate (the runner's attempt log, the
    /// resolver's ranking, the processor). Each ask scans the entire source
    /// HTML for lock declarations and parses it again for a truncation gate,
    /// which on a megabyte page costs more than half a second every time.
    var isReadable: Bool {
        readability.value { ArticleExtraction.isReadableArticle(content, html: sourceHTML) }
    }

    public static func == (lhs: ExtractedArticle, rhs: ExtractedArticle) -> Bool {
        lhs.content == rhs.content && lhs.sourceHTML == rhs.sourceHTML
    }
}

/// A compute-once Bool shared by every copy of the value that owns it.
private final class MemoizedVerdict: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: Bool?

    func value(_ compute: () -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let verdict = compute()
        cached = verdict
        return verdict
    }
}

/// Turns markup into structured `ArticleContent` and judges whether that
/// content is a readable article. `extract`/`extractFromJSONLD` delegate to
/// the pure `ArticleExtractor`; `fetchAndExtract` is the one bounded-I/O
/// helper every fetch-then-extract call site shares.
///
/// Extraction never knows that bypass exists; bypass only supplies candidate
/// HTML.
public struct ArticleExtraction {

    /// The stateless HTML-to-blocks parser. A shared instance is safe.
    private let extractor: ArticleExtractor

    public init(extractor: ArticleExtractor = ArticleExtractor()) {
        self.extractor = extractor
    }

    /// Parses `html` into structured content. Throws
    /// `ArticleExtractor.ExtractError` only when the document holds no usable
    /// text at all. Pure — no network access.
    public func extract(html: String, baseURL: URL) throws -> ArticleContent {
        try extractor.extract(html: html, baseURL: baseURL)
    }

    /// Extracts JSON-LD `articleBody` only, for the `.jsonLDBody` bypass
    /// strategy. Pure. Returns nil when the page carries no `articleBody`.
    public func extractFromJSONLD(html: String, baseURL: URL) -> ArticleContent? {
        extractor.extractFromJSONLD(html: html, baseURL: baseURL)
    }

    /// The one readable-vs-paywall-stub predicate. The resolver,
    /// `ArticleContent.hasReadableBody`, and `BypassGate` all share it. It
    /// returns true when the body clears the length threshold and doesn't
    /// read as a paywall, including the publisher-declared schema.org lock.
    /// Pass `html` whenever the source HTML is available, so the lock signal
    /// can't be bypassed by calling the text-only path instead. Pure.
    public static func isReadableArticle(_ content: ArticleContent, html: String?) -> Bool {
        content.bodyTextLength >= ArticleContent.readableBodyThreshold
            && !PaywallDetector.looksPaywalled(content: content, html: html)
    }

    /// The pair-shaped overload of `isReadableArticle`. The source HTML is
    /// always known here, and the pair remembers the answer, so repeated
    /// asks about the same candidate scan its HTML once.
    public static func isReadableArticle(_ article: ExtractedArticle) -> Bool {
        article.isReadable
    }

    /// Fetches HTML and extracts it, pairing the parsed content with its
    /// source HTML. Returns nil if the fetch or parse fails, so a dead source
    /// falls through gracefully. The one shared fetch-then-extract helper for
    /// the whole pipeline.
    ///
    /// `onFetchError` observes the swallowed error without changing the
    /// fall-through contract. A failed save needs to explain why the page was
    /// unreachable (403, offline, timeout), and this is the only place that
    /// error still exists. It defaults to nil, so existing call sites are
    /// unchanged.
    public func fetchAndExtract(
        baseURL: URL, fetch: () async throws -> String,
        onFetchError: ((Error) -> Void)? = nil
    ) async -> ExtractedArticle? {
        let html: String
        do {
            html = try await fetch()
        } catch {
            onFetchError?(error)
            SaveDiagnostics.record(
                "extract \(SaveDiagnostics.url(baseURL)): fetch failed — "
                    + SaveDiagnostics.snippet("\(error)"),
                category: "fetch")
            return nil
        }
        guard let content = try? extract(html: html, baseURL: baseURL) else {
            SaveDiagnostics.record(
                "extract \(SaveDiagnostics.url(baseURL)): \(html.count)ch of HTML "
                    + "yielded no extractable document",
                category: "ingest")
            return nil
        }
        SaveDiagnostics.record(
            "extract \(SaveDiagnostics.url(baseURL)): \(content.bodyTextLength)ch body, "
                + "title \(content.title.isEmpty ? "absent" : "present")",
            category: "ingest")
        return ExtractedArticle(content: content, sourceHTML: html)
    }
}

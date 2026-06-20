//
//  ArticleResolver.swift
//  ReaderKit
//

import Foundation
import SwiftSoup

/// The outcome of trying to read an article — directly first, then through the
/// public web archives. Modeled so invalid states can't arise: a readable result
/// always carries its content AND source HTML, a paywalled result always carries
/// a real (non-empty) title, and there's a distinct "nothing usable" case.
enum ArticleResolution: Equatable {
    /// A readable article was obtained (directly or from an archive). `html` is
    /// the winning source HTML, kept for cover-image extraction.
    case readable(ArticleContent, html: String)
    /// Only a paywall stub was reachable, but it carried a real title. The item
    /// can be parked for a user-solved archive CAPTCHA under this title.
    case paywalled(title: String)
    /// Nothing usable — not even a title.
    case unreadable

    static func == (lhs: ArticleResolution, rhs: ArticleResolution) -> Bool {
        switch (lhs, rhs) {
        case let (.readable(lc, lh), .readable(rc, rh)):
            return lc.title == rc.title && lc.bodyTextLength == rc.bodyTextLength && lh == rh
        case let (.paywalled(lt), .paywalled(rt)): return lt == rt
        case (.unreadable, .unreadable): return true
        default: return false
        }
    }
}

/// Resolves a web article into readable content, falling back to web archives for
/// hard-paywalled / bot-blocked pages (WSJ, FT, …). Shared by the main-app
/// ingestor and both share-sheet extensions so they agree on the strategy and the
/// "is this a real article vs. a paywall stub" threshold.
enum ArticleResolver {

    /// Fetches the article directly; if that yields only a paywall stub, tries the
    /// public web archives (Wayback, then archive.today). Returns the readable
    /// content when available, else the best title found (which survives even when
    /// only a stub was reachable — WSJ's title comes from the archive snapshot,
    /// FT's from the direct stub), else `.unreadable`.
    static func resolve(
        url: URL,
        fetcher: HTMLFetching = ArticleFetcher(),
        extractor: ArticleExtractor = ArticleExtractor(),
        runner: BypassRunning? = nil,
        replayLog: ((EventKind) async -> Void)? = nil
    ) async -> ArticleResolution {
        let direct = await extractedContent(from: { try await fetcher.fetchHTML(from: url) },
                                            baseURL: url, extractor: extractor)
        // Skip everything else when the direct read already succeeded.
        if Self.isReadable(direct) {
            return .readable(direct!.0, html: direct!.1)
        }

        // Walk the data-driven SILENT strategy list (per-host rule, else the generic
        // signal-based fallback). The first readable, non-locked extraction wins. The
        // WKWebView-only strategies (third-party reader pages, archive.today) are
        // skipped here and run later in the archive reader.
        let bypassRunner = runner ?? BypassRunner(fetcher: fetcher, extractor: extractor)
        let strategies = BypassStrategySelector.strategies(for: url, directHTML: direct?.1)
        for strategy in strategies where strategy.runsSilently {
            let pair = await bypassRunner.run(strategy, url: url, directHTML: direct?.1)
            let succeeded = pair.map(Self.isReadable) ?? false
            await replayLog?(.bypassStrategy(
                name: strategy.replayName, runsSilently: true, succeeded: succeeded))
            if let pair, Self.isReadable(pair) {
                return .readable(pair.0, html: pair.1)
            }
        }

        // No silent strategy worked. Try the legacy archive fetch as a last silent
        // attempt, then map to the resolution — preserving the title so the item
        // parks for the WKWebView archive path (unchanged downstream behavior).
        let archived = await extractedContent(from: { try await fetcher.fetchArchivedHTML(for: url) },
                                              baseURL: url, extractor: extractor)
        return resolution(direct: direct, archived: archived)
    }

    /// The page's advertised AMP URL (`<link rel="amphtml" href="…">`), absolute,
    /// or nil. AMP pages frequently lack the JS paywall overlay.
    static func ampURL(in html: String, base: URL) -> URL? {
        guard let doc = try? SwiftSoup.parse(html, base.absoluteString),
              let link = try? doc.select("link[rel=amphtml]").first(),
              let href = try? link.attr("abs:href"), !href.isEmpty,
              let url = URL(string: href), url.absoluteString != base.absoluteString
        else { return nil }
        return url
    }

    /// Picks the resolution from the (optional) direct and archived attempts. Pure
    /// (no I/O), so the title-preservation strategy is unit-testable: prefer a
    /// readable body from either source, else the best non-placeholder title
    /// (direct page first — it's canonical — then the archive snapshot), else
    /// `.unreadable`.
    static func resolution(
        direct: (ArticleContent, String)?, archived: (ArticleContent, String)?
    ) -> ArticleResolution {
        if Self.isReadable(direct) { return .readable(direct!.0, html: direct!.1) }
        if Self.isReadable(archived) { return .readable(archived!.0, html: archived!.1) }
        let title = [direct?.0.title, archived?.0.title]
            .compactMap { $0 }
            .first { !$0.isEmpty && $0 != "Untitled" }
        return title.map { .paywalled(title: $0) } ?? .unreadable
    }

    /// A fetched+extracted pair is "readable" only if it has a real body AND its
    /// source HTML doesn't declare a paywall (schema.org `isAccessibleForFree:false`
    /// etc.) — the latter catches walls whose CTA text the extractor stripped.
    private static func isReadable(_ pair: (ArticleContent, String)?) -> Bool {
        guard let pair else { return false }
        return pair.0.hasReadableBody && !PaywallDetector.htmlDeclaresLocked(pair.1)
    }

    /// Runs an HTML fetch and extracts it, pairing the parsed content with its
    /// source HTML. Returns nil if the fetch or parse fails.
    private static func extractedContent(
        from fetch: () async throws -> String, baseURL: URL, extractor: ArticleExtractor
    ) async -> (ArticleContent, String)? {
        guard let html = try? await fetch(),
              let content = try? extractor.extract(html: html, baseURL: baseURL)
        else { return nil }
        return (content, html)
    }
}

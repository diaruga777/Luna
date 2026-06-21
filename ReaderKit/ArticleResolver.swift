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
        prefetchedHTML: String? = nil,
        fetcher: HTMLFetching = ArticleFetcher(),
        extractor: ArticleExtractor = ArticleExtractor(),
        runner: BypassRunning? = nil,
        replayLog: ((EventKind) async -> Void)? = nil
    ) async -> ArticleResolution {
        let extraction = ArticleExtraction(extractor: extractor)
        // Reuse the caller's already-fetched direct HTML when supplied (the shared
        // decider fetches it once for product detection), else fetch it now.
        let direct = await extraction.fetchAndExtract(baseURL: url) {
            if let prefetchedHTML { return prefetchedHTML }
            return try await fetcher.fetchHTML(from: url)
        }
        // Skip everything else when the direct read already succeeded.
        if let direct, ArticleExtraction.isReadableArticle(direct) {
            return .readable(direct.content, html: direct.sourceHTML)
        }

        // Build the ONE typed bypass plan (per-host rule, else the generic
        // signal-based fallback) and walk its silent leg. The first readable,
        // non-locked extraction wins. The WKWebView strategies (third-party reader
        // pages, archive.today) live in the plan's web leg and run later in the
        // archive reader. A bounded aggregate deadline keeps the ingest path from
        // serially burning a minute of silent fetches before parking.
        let bypassRunner = runner ?? BypassRunner(fetcher: fetcher, extractor: extractor)
        let plan = BypassPlan.make(for: url, directHTML: direct?.sourceHTML)
        let silentDeadline = Date().addingTimeInterval(BypassPlan.silentChainDeadlineSeconds)
        for strategy in plan.silent {
            let candidate = await bypassRunner.run(strategy.asBypassStrategy, url: url,
                                                   directHTML: direct?.sourceHTML)
            let succeeded = candidate.map(ArticleExtraction.isReadableArticle) ?? false
            await replayLog?(.bypassStrategy(
                name: strategy.asBypassStrategy.replayName, runsSilently: true, succeeded: succeeded))
            if let candidate, ArticleExtraction.isReadableArticle(candidate) {
                return .readable(candidate.content, html: candidate.sourceHTML)
            }
            if Date() > silentDeadline { break }
        }

        // No silent strategy worked. Map to the resolution — preserving the title so
        // the item parks for the WKWebView archive path. (The legacy `fetchArchivedHTML`
        // last-silent attempt was dropped: `.waybackRaw` already covers Wayback in every
        // rule, and `archive.ph/newest` belongs to the bounded WKWebView terminal flow,
        // not a silent fetch — removing the duplicate Wayback hit + near-always-failing
        // archive.ph GET is the NYT/WSJ "no silent strategy worked" speed fix.)
        return resolution(direct: direct, archived: nil)
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
    /// `.unreadable`. Judged by the shared `ArticleExtraction.isReadableArticle`
    /// predicate (the only place the readable/locked decision lives).
    static func resolution(
        direct: ExtractedArticle?, archived: ExtractedArticle?
    ) -> ArticleResolution {
        if let direct, ArticleExtraction.isReadableArticle(direct) {
            return .readable(direct.content, html: direct.sourceHTML)
        }
        if let archived, ArticleExtraction.isReadableArticle(archived) {
            return .readable(archived.content, html: archived.sourceHTML)
        }
        let title = [direct?.content.title, archived?.content.title]
            .compactMap { $0 }
            .first { !$0.isEmpty && $0 != "Untitled" }
        return title.map { .paywalled(title: $0) } ?? .unreadable
    }
}

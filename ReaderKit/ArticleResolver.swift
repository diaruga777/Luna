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
        fetcher: ArticleFetcher = ArticleFetcher(),
        extractor: ArticleExtractor = ArticleExtractor()
    ) async -> ArticleResolution {
        let direct = await extractedContent(from: { try await fetcher.fetchHTML(from: url) },
                                            baseURL: url, extractor: extractor)
        // Skip everything else when the direct read already succeeded.
        if let direct, direct.0.hasReadableBody {
            return .readable(direct.0, html: direct.1)
        }
        // The page's AMP version is frequently served without the paywall overlay.
        if let direct, let ampURL = Self.ampURL(in: direct.1, base: url) {
            let amp = await extractedContent(from: { try await fetcher.fetchHTML(from: ampURL) },
                                             baseURL: ampURL, extractor: extractor)
            if let amp, amp.0.hasReadableBody { return .readable(amp.0, html: amp.1) }
        }
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
        if let direct, direct.0.hasReadableBody { return .readable(direct.0, html: direct.1) }
        if let archived, archived.0.hasReadableBody { return .readable(archived.0, html: archived.1) }
        let title = [direct?.0.title, archived?.0.title]
            .compactMap { $0 }
            .first { !$0.isEmpty && $0 != "Untitled" }
        return title.map { .paywalled(title: $0) } ?? .unreadable
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

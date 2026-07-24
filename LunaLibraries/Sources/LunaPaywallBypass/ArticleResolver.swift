//
//  ArticleResolver.swift
//  ReaderKit
//

import LunaFetch
import LunaHTMLClassification
import LunaModels
import Foundation
import SwiftSoup

/// The outcome of trying to read an article — directly first, then through the
/// public web archives. Modeled so invalid states can't arise: a readable result
/// always carries its content AND source HTML, a paywalled result always carries
/// a real (non-empty) title, and there's a distinct "nothing usable" case.
public enum ArticleResolution: Equatable {
    /// A readable article was obtained (directly or from an archive). `html` is
    /// the winning source HTML, kept for cover-image extraction.
    case readable(ArticleContent, html: String)
    /// Only a paywall stub was reachable, but it carried a real title. The item
    /// can be parked for a user-solved archive CAPTCHA under this title.
    case paywalled(title: String)
    /// Nothing usable — not even a title.
    case unreadable

    public static func == (lhs: ArticleResolution, rhs: ArticleResolution) -> Bool {
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
public enum ArticleResolver {

    /// Fetches the article directly; if that yields only a paywall stub, tries the
    /// public web archives (Wayback, then archive.today). Returns the readable
    /// content when available, else the best title found (which survives even when
    /// only a stub was reachable — WSJ's title comes from the archive snapshot,
    /// FT's from the direct stub), else `.unreadable`.
    public static func resolve(
        url: URL,
        prefetchedHTML: String? = nil,
        fetcher: HTMLFetching = ArticleFetcher(),
        extractor: ArticleExtractor = ArticleExtractor(),
        runner: BypassRunning? = nil,
        trustsPrefetchedHTML: Bool = false
    ) async -> ArticleResolution {
        let extraction = ArticleExtraction(extractor: extractor)
        let siteRule = SiteUnlockRules.rule(for: url)
        // Reuse the caller's already-fetched direct HTML when supplied (the shared
        // decider fetches it once for product detection), else fetch it now.
        let direct = await extraction.fetchAndExtract(baseURL: url) {
            if let prefetchedHTML { return prefetchedHTML }
            return try await fetcher.fetchHTML(from: url)
        }
        // Skip everything else when the direct read already succeeded. A TRUSTED
        // prefetch (the Safari "Read in Luna" hand-off, which captured the already-
        // unlocked on-screen article) is accepted on body length alone: the page's
        // stale schema.org lock would otherwise re-reject the very content the user is
        // looking at, sending them back through the whole archive dance.
        //
        // But a capture that STILL reads as locked is only a FLOOR, never the winner,
        // when this host has a site-unlock rule: Safari can apply the rule's
        // script-blocking half yet cannot spoof the request User-Agent, so a partially
        // unlocked capture may be the publisher's TRUNCATED render (NYT sends the whole
        // body and truncates the DOM client-side — a hand-off of that is 2k readable
        // characters of a 5k article). The one silent rule fetch below can do what the
        // browser could not; the capture stays as the fallback, so consulting it can
        // only improve the result, and a host with no rule still returns immediately.
        var trustedCapture: ExtractedArticle?
        if let direct {
            if ArticleExtraction.isReadableArticle(direct) {
                return .readable(direct.content, html: direct.sourceHTML)
            }
            if trustsPrefetchedHTML, prefetchedHTML != nil,
               direct.content.bodyTextLength >= ArticleContent.readableBodyThreshold {
                guard siteRule != nil else {
                    return .readable(direct.content, html: direct.sourceHTML)
                }
                trustedCapture = direct
            }
        }

        // Build the ONE typed bypass plan (per-host rule, else the generic
        // signal-based fallback) and walk its silent leg. The first readable,
        // non-locked extraction wins. The WKWebView strategies (third-party reader
        // pages, archive.today) live in the plan's web leg and run later in the
        // archive reader. A bounded aggregate deadline keeps the ingest path from
        // serially burning a minute of silent fetches before parking.
        // A site unlock rule → run the rule's silent request technique
        // (crawler/custom UA or spoofed Referer) and a forced JSON-LD reconstruction
        // before parking for the browser tier. Kept out of the strategy enum because
        // the rule carries arbitrary UA/referer strings the enum can't express.
        if let rule = siteRule {
            // Never trade a trusted capture DOWN: a rule fetch can come back readable
            // (no lock declaration, over the threshold) and still be shorter than what
            // the user already had on screen.
            let floor = trustedCapture?.content.bodyTextLength ?? 0
            if let html = try? await SiteUnlockSilent.fetch(url: url, rule: rule, fetcher: fetcher),
               let candidate = await extraction.fetchAndExtract(baseURL: url, fetch: { html }),
               ArticleExtraction.isReadableArticle(candidate),
               candidate.content.bodyTextLength >= floor {
                return .readable(candidate.content, html: candidate.sourceHTML)
            }
            if let directHTML = direct?.sourceHTML,
               let content = extraction.extractFromJSONLD(html: directHTML, baseURL: url) {
                let reconstructed = ExtractedArticle(content: content, sourceHTML: directHTML)
                if ArticleExtraction.isReadableArticle(reconstructed),
                   content.bodyTextLength >= floor {
                    return .readable(content, html: directHTML)
                }
            }
        }

        // The rule couldn't beat the capture. Hand back what the user is already
        // looking at rather than walking the generic bypass chain: a live browser
        // capture beats anything a background fetch will find, and the user is waiting.
        if let trustedCapture {
            return .readable(trustedCapture.content, html: trustedCapture.sourceHTML)
        }

        let bypassRunner = runner ?? BypassRunner(fetcher: fetcher, extractor: extractor)
        let plan = BypassPlan.make(for: url, directHTML: direct?.sourceHTML)
        let silentDeadline = Date().addingTimeInterval(BypassPlan.silentChainDeadlineSeconds)
        for strategy in plan.silent {
            let candidate = await bypassRunner.run(strategy.asBypassStrategy, url: url,
                                                   directHTML: direct?.sourceHTML)
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
    public static func ampURL(in html: String, base: URL) -> URL? {
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
    public static func resolution(
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

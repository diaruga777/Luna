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
    ///
    /// This case means "a wall stands between us and a real article", NOT merely
    /// "unreadable but titled" — see `resolution(direct:archived:...)`.
    case paywalled(title: String)
    /// Nothing usable — not even a title. Carries WHY when the direct fetch's
    /// error was captured (403 / offline / timeout / not-HTML), so the failed
    /// card can say more than "couldn't fetch"; nil when the page came back
    /// fine and simply had no article and no title in it.
    case unreadable(SaveFailureReason?)

    public static func == (lhs: ArticleResolution, rhs: ArticleResolution) -> Bool {
        switch (lhs, rhs) {
        case let (.readable(lc, lh), .readable(rc, rh)):
            return lc.title == rc.title && lc.bodyTextLength == rc.bodyTextLength && lh == rh
        case let (.paywalled(lt), .paywalled(rt)): return lt == rt
        case let (.unreadable(l), .unreadable(r)): return l == r
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
        // The direct read's error is the ONE that explains a total failure, so it
        // is captured here and carried into `.unreadable` at the bottom.
        var directFailure: SaveFailureReason?
        let direct = await extraction.fetchAndExtract(
            baseURL: url,
            fetch: {
                if let prefetchedHTML { return prefetchedHTML }
                return try await fetcher.fetchHTML(from: url)
            },
            onFetchError: { directFailure = SaveFailureReason(fetchError: $0) })
        // Skip everything else when the direct read already succeeded. A TRUSTED
        // prefetch (the Safari "Read in Luna" hand-off, which captured the already-
        // unlocked on-screen article) is accepted on body length alone: the page's
        // stale schema.org lock would otherwise re-reject the very content the user is
        // looking at, sending them back through the whole archive dance.
        //
        // But a capture that STILL reads as locked is only a FLOOR, never the winner:
        // Safari can apply a rule's script-blocking half yet cannot spoof the request
        // User-Agent, so a partially unlocked capture may be the publisher's TRUNCATED
        // render (NYT sends the whole body and truncates the DOM client-side — a hand-off
        // of that is 2k readable characters of a 5k article), and on a
        // generous-preview site the browser is looking at a body the SERVER already cut
        // short, which no amount of on-page unlocking can restore. The silent tier below
        // can do what the browser could not; the capture stays as the fallback, so
        // consulting it can only improve the result.
        var trustedCapture: ExtractedArticle?
        if let direct {
            if ArticleExtraction.isReadableArticle(direct) {
                return .readable(direct.content, html: direct.sourceHTML)
            }
            if trustsPrefetchedHTML, prefetchedHTML != nil,
               direct.content.bodyTextLength >= ArticleContent.readableBodyThreshold {
                trustedCapture = direct
            }
        }

        // Build the ONE typed bypass plan (per-host rule, else the generic
        // signal-based fallback) and run its silent leg. The WKWebView strategies
        // (third-party reader pages, archive.today) live in the plan's web leg and run
        // later in the archive reader.
        //
        // A site unlock rule contributes two more silent attempts AHEAD of the plan's:
        // the rule's own request technique (crawler/custom UA or spoofed Referer) and a
        // forced JSON-LD reconstruction. They're kept out of the strategy enum because
        // the rule carries arbitrary UA/referer strings the enum can't express — but
        // they are the same TIER, so they belong in the same ordered list.
        //
        // Never trade a trusted capture DOWN: a rule fetch or an archive snapshot can
        // come back readable (no lock declaration, over the threshold) and still be
        // shorter than what the user already had on screen.
        let floor = trustedCapture?.content.bodyTextLength ?? 0
        let bypassRunner = runner ?? BypassRunner(fetcher: fetcher, extractor: extractor)
        let directHTML = direct?.sourceHTML
        let plan = BypassPlan.make(for: url, directHTML: directHTML)

        var attempts: [@Sendable () async -> ExtractedArticle?] = []
        if let rule = siteRule {
            attempts.append {
                guard let html = try? await SiteUnlockSilent.fetch(
                    url: url, rule: rule, fetcher: fetcher) else { return nil }
                return await extraction.fetchAndExtract(baseURL: url, fetch: { html })
            }
            attempts.append {
                guard let directHTML,
                      let content = extraction.extractFromJSONLD(html: directHTML, baseURL: url)
                else { return nil }
                return ExtractedArticle(content: content, sourceHTML: directHTML)
            }
        }
        attempts += plan.silent.map { strategy in
            { await bypassRunner.run(strategy.asBypassStrategy, url: url, directHTML: directHTML) }
        }

        // A trusted capture is already on screen, so the chain is a bounded attempt to
        // IMPROVE it, not the thing the user is waiting for — it gets the shorter budget.
        let silentDeadline = Date().addingTimeInterval(
            trustedCapture == nil
                ? BypassPlan.silentChainDeadlineSeconds
                : BypassPlan.trustedCaptureSilentDeadlineSeconds)
        if let winner = await firstQualifying(attempts, deadline: silentDeadline, floor: floor) {
            return .readable(winner.content, html: winner.sourceHTML)
        }

        // Nothing beat the capture. Hand back what the user is already looking at rather
        // than parking the item for the browser tier: a live browser capture is real
        // content, and the user is waiting on it.
        if let trustedCapture {
            return .readable(trustedCapture.content, html: trustedCapture.sourceHTML)
        }

        // No silent strategy worked. Map to the resolution — preserving the title so
        // the item parks for the WKWebView archive path. (The legacy `fetchArchivedHTML`
        // last-silent attempt was dropped: `.waybackRaw` covers Wayback in every plan,
        // and `archive.ph/newest` belongs to the bounded WKWebView terminal flow,
        // not a silent fetch — removing the duplicate Wayback hit + near-always-failing
        // archive.ph GET is the NYT/WSJ "no silent strategy worked" speed fix.)
        // `plan.allowsArchiveToday` is the gate's verdict, already computed: it is
        // true only when `BypassGate` found real paywall evidence (a declared lock,
        // a gate marker, a hard-paywall host, an archive URL, or a fetch that never
        // came back) or a site rule applies. Handing it to `resolution` is what stops
        // EVERY titled-but-unreadable page from parking for the archive reader.
        return resolution(
            direct: direct, archived: nil, directFailure: directFailure,
            parksForArchive: plan.allowsArchiveToday)
    }

    /// Runs every silent attempt CONCURRENTLY and returns the first one — in LIST order,
    /// not completion order — that clears the readability gate and the trusted-capture
    /// `floor`. Nil when none does, or when `deadline` passes first.
    ///
    /// Concurrency here is the whole reason a hard-paywalled save is quick. The
    /// strategies are independent GETs against DIFFERENT servers (the publisher, the
    /// Wayback index, an archive replay), so running them one after another made the
    /// wall clock their SUM: a WSJ article spent ~30s in the Wayback index alone, twice
    /// blowing past `IngestPipeline`'s 28s ceiling, and the extension sat on a spinner
    /// that looked hung. Fanning them out makes it the MAX instead.
    ///
    /// Resolving by list order rather than by whoever finishes first keeps the OUTCOME
    /// identical to the old serial walk: a cheap-but-weaker strategy that happens to
    /// answer first still can't beat a better one that was ranked above it. Once a
    /// winner is settled the rest are cancelled, so a fast win doesn't pay for the
    /// downloads it made unnecessary.
    private static func firstQualifying(
        _ attempts: [@Sendable () async -> ExtractedArticle?],
        deadline: Date, floor: Int
    ) async -> ExtractedArticle? {
        guard !attempts.isEmpty else { return nil }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return nil }

        /// The deadline leg reports under this index so it's distinguishable from a
        /// real attempt without a second channel.
        let deadlineIndex = -1
        return await withTaskGroup(of: (Int, ExtractedArticle?).self) { group in
            for (index, attempt) in attempts.enumerated() {
                group.addTask { (index, await attempt()) }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                return (deadlineIndex, nil)
            }
            defer { group.cancelAll() }

            // `settled[i]` holds attempt i's result once it lands. `next` is the
            // highest-ranked attempt still undecided: everything below it has already
            // answered and lost, so the moment `next` answers with a qualifying article
            // nothing left in flight could outrank it.
            var settled: [Int: ExtractedArticle?] = [:]
            var next = 0
            while let (index, candidate) = await group.next() {
                if index == deadlineIndex { return nil }
                settled[index] = candidate
                while next < attempts.count, let decided = settled[next] {
                    if let decided, ArticleExtraction.isReadableArticle(decided),
                       decided.content.bodyTextLength >= floor {
                        return decided
                    }
                    next += 1
                }
                if next == attempts.count { return nil }
            }
            return nil
        }
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
    /// - Parameter directFailure: why the direct fetch threw, when it did. Only
    ///   reaches the result in the `.unreadable` case — a page that yielded a
    ///   title or a body wasn't a failure at all.
    /// - Parameter parksForArchive: whether the archive tier is a legitimate next
    ///   step for this page — `BypassPlan.allowsArchiveToday`, i.e. `BypassGate`
    ///   found paywall evidence. A `<title>` is NOT that evidence: every web page
    ///   has one, so returning `.paywalled` on a title alone sent Google's
    ///   homepage, a search-results page, and every JS shell into the
    ///   archive.today CAPTCHA reader (and, via `.needsArchive`, into the Safari
    ///   recents tray as a would-be article). Defaults to true so the pure
    ///   title-preference tests below can exercise it in isolation; the one
    ///   production caller always passes the plan's verdict.
    public static func resolution(
        direct: ExtractedArticle?, archived: ExtractedArticle?,
        directFailure: SaveFailureReason? = nil,
        parksForArchive: Bool = true
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
        if parksForArchive, let title { return .paywalled(title: title) }
        // Reached the page but found no article and no title: that's a readable-
        // content failure, not a transport one, whatever the fetch reported.
        return .unreadable(direct == nil ? directFailure : .notReadable)
    }
}

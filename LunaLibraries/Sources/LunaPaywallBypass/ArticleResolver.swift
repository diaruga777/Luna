//
//  ArticleResolver.swift
//  ReaderKit
//

import LunaFetch
import LunaHTMLClassification
import LunaModels
import Foundation
import SwiftSoup

/// The outcome of trying to read an article — directly first, then through
/// the public web archives. Modeled so invalid states cannot arise: a
/// readable result always carries its content and source HTML, a paywalled
/// result always carries a real, non-empty title, and there is a distinct
/// "nothing usable" case.
public enum ArticleResolution: Equatable {
    /// A readable article was obtained (directly or from an archive). `html` is
    /// the winning source HTML, kept for cover-image extraction.
    case readable(ArticleContent, html: String)
    /// Only a paywall stub was reachable, but it carried a real title. The item
    /// can be parked for a user-solved archive CAPTCHA under this title.
    ///
    /// This case means "a wall stands between us and a real article", not
    /// merely "unreadable but titled" — see `resolution(direct:archived:...)`.
    case paywalled(title: String)
    /// Nothing usable — not even a title. Carries the reason when the direct
    /// fetch's error was captured (403, offline, timeout, not-HTML), so the
    /// failed card can say more than "couldn't fetch"; nil when the page
    /// came back fine and simply had no article and no title in it.
    case unreadable(SaveFailureReason?)

    /// One line for the per-save trace — shapes, never the body.
    var diagnosticSummary: String {
        switch self {
        case let .readable(content, html):
            return "readable, \(content.bodyTextLength)ch body from \(html.count)ch HTML"
        case let .paywalled(title):
            return "paywalled, parking for the archive reader as "
                + "\"\(SaveDiagnostics.snippet(title, limit: 80))\""
        case let .unreadable(reason):
            return "unreadable (\(reason.map { String(describing: $0) } ?? "no detail"))"
        }
    }

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
        page: CapturedPage = .none,
        fetcher: HTMLFetching = ArticleFetcher(),
        extractor: ArticleExtractor = ArticleExtractor(),
        runner: BypassRunning? = nil
    ) async -> ArticleResolution {
        let extraction = ArticleExtraction(extractor: extractor)
        let siteRule = SiteUnlockRules.rule(for: url)
        // Reuse the caller's already-fetched direct HTML when supplied (the
        // shared decider fetches it once for product detection), else fetch
        // it now. The direct read's error is the one that explains a total
        // failure, so it is captured here and carried into `.unreadable` at
        // the bottom.
        var directFailure: SaveFailureReason?
        let direct = await extraction.fetchAndExtract(
            baseURL: url,
            fetch: {
                if let html = page.html { return html }
                return try await fetcher.fetchHTML(from: url)
            },
            onFetchError: { directFailure = SaveFailureReason(fetchError: $0) })
        // Skip everything else when the direct read already succeeded. A
        // trusted prefetch (the Safari "Read in Luna" hand-off, which
        // captured the already-unlocked on-screen article) is accepted on
        // body length alone: the page's stale schema.org lock would
        // otherwise re-reject the very content the user is looking at,
        // sending them back through the whole archive dance.
        //
        // But a capture that still reads as locked is only a floor, never
        // the winner: Safari can apply a rule's script-blocking half yet
        // cannot spoof the request User-Agent, so a partially unlocked
        // capture may be the publisher's truncated render (NYT sends the
        // whole body and truncates the DOM client-side — a hand-off of that
        // is 2k readable characters of a 5k article), and on a
        // generous-preview site the browser is looking at a body the server
        // already cut short, which no amount of on-page unlocking can
        // restore. The silent tier below can do what the browser could not;
        // the capture stays as the fallback, so consulting it can only
        // improve the result.
        var trustedCapture: ExtractedArticle?
        SaveDiagnostics.record(
            "resolve \(SaveDiagnostics.url(url)): direct read "
                + (direct.map { "\($0.content.bodyTextLength)ch, "
                    + "\(ArticleExtraction.isReadableArticle($0) ? "readable" : "not readable")" }
                    ?? "failed (\(directFailure.map { String(describing: $0) } ?? "no detail"))")
                + (siteRule != nil ? ", site unlock rule applies" : ""),
            category: "bypass")
        if let direct {
            if ArticleExtraction.isReadableArticle(direct) {
                return .readable(direct.content, html: direct.sourceHTML)
            }
            if case .unlockedCapture = page,
               direct.content.bodyTextLength >= ArticleContent.readableBodyThreshold {
                trustedCapture = direct
            }
        }

        // Build the one typed bypass plan (per-host rule, else the generic
        // signal-based fallback) and run its silent leg. The WKWebView
        // strategies (third-party reader pages, archive.today) live in the
        // plan's web leg and run later in the archive reader.
        //
        // A site unlock rule contributes two more silent attempts ahead of
        // the plan's: the rule's own request technique (crawler/custom UA or
        // spoofed Referer) and a forced JSON-LD reconstruction. They are kept
        // out of the strategy enum because the rule carries arbitrary
        // UA/referer strings the enum cannot express, but they are the same
        // tier, so they belong in the same ordered list.
        //
        // Never trade a trusted capture down: a rule fetch or an archive
        // snapshot can come back readable (no lock declaration, over the
        // threshold) and still be shorter than what the user already had on
        // screen.
        let floor = trustedCapture?.content.bodyTextLength ?? 0
        let bypassRunner = runner ?? BypassRunner(fetcher: fetcher, extractor: extractor)
        let directHTML = direct?.sourceHTML
        let plan = BypassPlan.make(for: url, directHTML: directHTML, directFailure: directFailure)
        SaveDiagnostics.record(
            "resolve: plan — silent [\(plan.silent.map { "\($0)" }.joined(separator: ", "))], "
                + "web [\(plan.webPreStages.map { "\($0)" }.joined(separator: ", "))], "
                + "archiveToday \(plan.allowsArchiveToday ? "allowed" : "refused")",
            category: "bypass")

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

        // A trusted capture is already on screen, so the chain is a bounded
        // attempt to improve it, not the thing the user is waiting for; it
        // gets the shorter budget.
        let silentDeadline = Date().addingTimeInterval(
            trustedCapture == nil
                ? BypassPlan.silentChainDeadlineSeconds
                : BypassPlan.trustedCaptureSilentDeadlineSeconds)
        SaveDiagnostics.record(
            "resolve: running \(attempts.count) silent attempt(s), "
                + "\(Int(silentDeadline.timeIntervalSinceNow))s budget, floor \(floor)ch",
            category: "bypass")
        if let winner = await firstQualifying(attempts, deadline: silentDeadline, floor: floor) {
            SaveDiagnostics.record(
                "resolve: silent tier won with \(winner.content.bodyTextLength)ch",
                category: "bypass")
            return .readable(winner.content, html: winner.sourceHTML)
        }
        SaveDiagnostics.record("resolve: no silent strategy qualified", category: "bypass")

        // Nothing beat the capture. Hand back what the user is already looking at rather
        // than parking the item for the browser tier: a live browser capture is real
        // content, and the user is waiting on it.
        if let trustedCapture {
            return .readable(trustedCapture.content, html: trustedCapture.sourceHTML)
        }

        // No silent strategy worked. Map to the resolution — preserving the
        // title so the item parks for the WKWebView archive path.
        // `plan.allowsArchiveToday` is the gate's verdict, already computed:
        // it is true only when `BypassGate` found real paywall evidence (a
        // declared lock, a gate marker, a hard-paywall host, an archive URL,
        // or a fetch that never came back) or a site rule applies. Handing
        // it to `resolution` is what stops every titled-but-unreadable page
        // from parking for the archive reader.
        let resolved = resolution(
            direct: direct, archived: nil, directFailure: directFailure,
            parksForArchive: plan.allowsArchiveToday)
        SaveDiagnostics.record("resolve: \(resolved.diagnosticSummary)", category: "bypass")
        return resolved
    }

    /// Runs every silent attempt concurrently and returns the first one — in
    /// list order, not completion order — that clears the readability gate
    /// and the trusted-capture `floor`. Nil when none does, or when
    /// `deadline` passes first.
    ///
    /// Concurrency here is the whole reason a hard-paywalled save is quick.
    /// The strategies are independent GETs against different servers (the
    /// publisher, the Wayback index, an archive replay). Running them one
    /// after another would make the wall clock their sum: a WSJ article
    /// spends about 30s in the Wayback index alone, twice past
    /// `IngestPipeline`'s 28s ceiling on its own, which would leave the
    /// extension sitting on a spinner that looks hung. Fanning them out
    /// makes the wall clock the max instead.
    ///
    /// Resolving by list order rather than by whoever finishes first
    /// preserves rank: a cheap-but-weaker strategy that happens to answer
    /// first still cannot beat a better one that was ranked above it. Once a
    /// winner is settled the rest are cancelled, so a fast win does not pay
    /// for the downloads it made unnecessary.
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
    /// - Parameter parksForArchive: whether the archive tier is a legitimate
    ///   next step for this page — `BypassPlan.allowsArchiveToday`, i.e.
    ///   `BypassGate` found paywall evidence. A `<title>` is not that
    ///   evidence: every web page has one, so returning `.paywalled` on a
    ///   title alone would send Google's homepage, a search-results page,
    ///   and every JS shell into the archive.today CAPTCHA reader (and, via
    ///   `.needsArchive`, into the Safari recents tray as a would-be
    ///   article). Defaults to true so the pure title-preference tests below
    ///   can exercise it in isolation; the one production caller always
    ///   passes the plan's verdict.
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

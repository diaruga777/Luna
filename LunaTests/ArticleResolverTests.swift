//
//  ArticleResolverTests.swift
//  LunaTests
//

import LunaArticleIngest
import LunaPaywallBypass
import LunaHTMLClassification
import LunaModels
import XCTest
@testable import Luna

final class ArticleResolverTests: XCTestCase {

    /// A paragraph block of `length` characters.
    private func content(title: String, bodyLength: Int) -> ArticleContent {
        let body = String(repeating: "a", count: bodyLength)
        return ArticleContent(title: title, blocks: [.init(kind: .paragraph, text: body, links: [])])
    }

    /// An `ExtractedArticle` of `bodyLength` characters with `title`.
    private func extracted(title: String, bodyLength: Int, html: String) -> ExtractedArticle {
        ExtractedArticle(content: content(title: title, bodyLength: bodyLength), sourceHTML: html)
    }

    /// The whole `resolution(direct:archived:directFailure:)` decision table in one
    /// sweep: every (direct, archived, captured-failure) shape and the resolution it
    /// must produce. Each row names the real case it encodes and that name is the
    /// failure message, so a break points at the row rather than at the file.
    func testResolutionDecisionTable() {
        let readableDirect = content(title: "Real", bodyLength: 2000)
        let readableArchive = content(title: "Paywalled", bodyLength: 2000)

        let cases: [(
            why: String,
            direct: ExtractedArticle?,
            archived: ExtractedArticle?,
            directFailure: SaveFailureReason?,
            expected: ArticleResolution
        )] = [
            (
                "a readable direct read wins and skips the archive",
                ExtractedArticle(content: readableDirect, sourceHTML: "<html>direct</html>"),
                nil, nil,
                .readable(readableDirect, html: "<html>direct</html>")
            ),
            (
                "a readable archive is used when the direct read is a stub",
                extracted(title: "Paywalled", bodyLength: 50, html: "<stub>"),
                ExtractedArticle(content: readableArchive, sourceHTML: "<archive>"), nil,
                .readable(readableArchive, html: "<archive>")
            ),
            (
                // FT-shaped: the direct fetch returns a titled subscription stub and
                // the archive fetch fails entirely — the title must survive.
                "a direct stub's title survives when the archive fails",
                extracted(title: "FT Headline", bodyLength: 80, html: "<stub>"),
                nil, nil,
                .paywalled(title: "FT Headline")
            ),
            (
                // WSJ-shaped: the direct fetch 401s (no content at all) but the
                // archive snapshot, while itself paywalled, still carries the title.
                "the archive's title is used when the direct read fails outright",
                nil,
                extracted(title: "WSJ Headline", bodyLength: 120, html: "<archive>"), nil,
                .paywalled(title: "WSJ Headline")
            ),
            (
                "the direct title is preferred over the archive's copy of it",
                extracted(title: "Canonical", bodyLength: 40, html: "<stub>"),
                extracted(title: "Archive Copy", bodyLength: 60, html: "<archive>"), nil,
                .paywalled(title: "Canonical")
            ),
            (
                // The page WAS reached — it just held nothing usable — so the reason
                // is a content failure, never whatever the transport reported.
                "a placeholder title is not treated as a real one",
                extracted(title: "Untitled", bodyLength: 40, html: "<stub>"),
                nil, nil,
                .unreadable(.notReadable)
            ),
            (
                // A page that never came back carries the fetch's own reason forward,
                // so the failed card can say "403" instead of "couldn't fetch".
                "an unreachable page carries the fetch reason",
                nil, nil, .httpStatus(403),
                .unreadable(.httpStatus(403))
            ),
            (
                // A reached-but-empty page must NOT inherit the direct fetch's reason:
                // the direct read here succeeded, and any captured error belongs to an
                // earlier attempt.
                "a reached page ignores a stale fetch reason",
                extracted(title: "", bodyLength: 10, html: "<stub>"),
                nil, .offline,
                .unreadable(.notReadable)
            ),
            (
                "nothing reachable at all is unreadable with no reason",
                nil, nil, nil,
                .unreadable(nil)
            ),
        ]

        for c in cases {
            let result = ArticleResolver.resolution(
                direct: c.direct, archived: c.archived, directFailure: c.directFailure)
            XCTAssertEqual(result, c.expected, c.why)
        }
    }

    // MARK: - silent-strategy loop: advance-on-failure (GOAL 2 routing reliability)

    /// A long readable article body so extraction clears the readability gate.
    private func readableHTML(_ marker: String) -> String {
        let paragraph = "<p>" + String(repeating: "An ordinary readable sentence about \(marker). ", count: 30) + "</p>"
        return "<html><head><title>Real \(marker)</title></head><body><article>\(paragraph)\(paragraph)</article></body></html>"
    }

    /// A locked teaser (short body + schema.org lock) that must be REJECTED.
    private let lockedHTML = "<html><head><title>NYT Headline</title></head><body><p>Lede only.</p>"
        + #"<script type="application/ld+json">{"@type":"NewsArticle","isAccessibleForFree":false}</script>"#
        + "</body></html>"

    /// A site unlock rule (WSJ → Referer:Drudge): the resolver runs the
    /// rule's silent request technique. Here the Drudge-referer fetch returns the full
    /// article, so it wins before any browser-tier / archive fallback.
    func testResolverSilentRefererUnlockWinsForWSJ() async {
        let articleURL = URL(string: "https://www.wsj.com/articles/x_199845b1.html")!
        let fetcher = MockArticleFetcher()
        fetcher.htmlByURL[articleURL.absoluteString] = lockedHTML             // direct read = locked
        fetcher.refererHTMLByURL[articleURL.absoluteString] = readableHTML("drudge")  // referer read = full

        let result = await ArticleResolver.resolve(url: articleURL, fetcher: fetcher)
        if case .readable = result {} else { return XCTFail("expected readable, got \(result)") }
        // The silent leg used a Drudge-referer fetch (WSJ's rule), not a crawler UA.
        let refererCall = fetcher.calls.first { $0.kind == .referer }
        XCTAssertEqual(refererCall?.referer, "https://www.drudgereport.com/")
    }

    /// For WSJ, the silent Referer fetch stays locked and there's no
    /// JSON-LD body: the resolver parks it under its title for the browser-tier /
    /// archive flow rather than returning a locked page.
    func testResolverParksWhenSilentRefererStaysLocked() async {
        let articleURL = URL(string: "https://www.wsj.com/articles/x_199845b1.html")!
        let fetcher = MockArticleFetcher()
        // Both the direct AND the Drudge-referer fetch return the same locked teaser.
        fetcher.htmlByURL[articleURL.absoluteString] = lockedHTML

        let result = await ArticleResolver.resolve(url: articleURL, fetcher: fetcher)
        XCTAssertEqual(result, .paywalled(title: "NYT Headline"))   // lockedHTML's title
        XCTAssertTrue(fetcher.calls.contains { $0.kind == .referer })
    }

    /// A full, readable article body that ALSO still carries the publisher's
    /// schema.org lock — the shape of New Statesman subscriber pages and the Safari
    /// "Read in Luna" hand-off, where the body is present but the stale
    /// `isAccessibleForFree:false` remains in the page's JSON-LD.
    private func readableButLockedHTML(_ marker: String) -> String {
        let paragraph = "<p>" + String(repeating: "An ordinary readable sentence about \(marker). ", count: 30) + "</p>"
        return "<html><head><title>Real \(marker)</title>"
            + #"<script type="application/ld+json">{"@type":"NewsArticle","isAccessibleForFree":false}</script>"#
            + "</head><body><article>\(paragraph)\(paragraph)</article></body></html>"
    }

    /// New Statesman-shaped direct HTML can contain the full story while still declaring
    /// a schema.org lock. Long, gate-free article prose should resolve directly instead
    /// of parking for archive.today.
    func testLongDirectArticleBeatsStaleSchemaLock() async {
        let articleURL = URL(string: "https://www.newstatesman.com/world/asia/2026/07/in-hong-kong-i-saw-the-coming-chinese-century")!
        let html = readableButLockedHTML("newstatesman")
        let fetcher = MockArticleFetcher()
        fetcher.htmlByURL[articleURL.absoluteString] = html

        let result = await ArticleResolver.resolve(
            url: articleURL, fetcher: fetcher)
        if case .readable = result {} else { XCTFail("long direct body should be readable, got \(result)") }
        XCTAssertEqual(fetcher.calls.first?.kind, .plain)
    }

    /// The Safari hand-off still accepts shorter already-unlocked article DOMs on body
    /// length alone, because the page the user captured is trusted.
    func testTrustedSafariPrefetchBypassesShortStaleSchemaLock() async {
        let articleURL = URL(string: "https://www.wsj.com/articles/unlocked_199845b1.html")!
        let paragraph = "<p>" + String(repeating: "Short unlocked article sentence. ", count: 25) + "</p>"
        let html = "<html><head><title>Real wsj</title>"
            + #"<script type="application/ld+json">{"@type":"NewsArticle","isAccessibleForFree":false}</script>"#
            + "</head><body><article>\(paragraph)\(paragraph)</article></body></html>"

        let parked = await ArticleResolver.resolve(
            url: articleURL, page: .fetched(html), fetcher: MockArticleFetcher())
        if case .readable = parked { XCTFail("short untrusted prefetch must not bypass the schema lock") }

        let result = await ArticleResolver.resolve(
            url: articleURL, page: .safariHandoff(html: html), fetcher: MockArticleFetcher())
        if case .readable = result {} else { XCTFail("trusted prefetch should be readable, got \(result)") }
    }

    // MARK: - trusted Safari capture is a floor, not a winner

    /// Readable prose of `paragraphs` × 30 sentences, with no lock declaration.
    private func proseHTML(_ marker: String, paragraphs: Int) -> String {
        let paragraph = "<p>" + String(repeating: "An ordinary readable sentence about \(marker). ", count: 30) + "</p>"
        return "<html><head><title>Real \(marker)</title></head><body><article>"
            + String(repeating: paragraph, count: paragraphs) + "</article></body></html>"
    }

    /// The NYT-shaped Safari capture: the publisher's TRUNCATED render. Over the
    /// readable threshold (1200) so a trusted hand-off accepts it on length, but under
    /// `PaywallDetector.shortBodyThreshold` (2500) so its schema.org lock still counts —
    /// the live article measures ~2.2k rendered characters of a ~4.6k body.
    private func truncatedLockedCaptureHTML() -> String {
        let paragraph = "<p>" + String(repeating: "An ordinary sentence from the enzyme study. ", count: 24) + "</p>"
        return "<html><head><title>NYT Enzyme Story</title>"
            + #"<script type="application/ld+json">{"@type":"NewsArticle","isAccessibleForFree":false}</script>"#
            + "</head><body><article>\(paragraph)\(paragraph)</article></body></html>"
    }

    /// The Paris Review shape: a LONG readable preview (no metadata lock, far over every
    /// length threshold) that the server cut off, with the subscribe gate standing where
    /// the rest of the interview should be. Only `TruncationGateDetector` can see this.
    private func truncatedPreviewHTML(paragraphs: Int) -> String {
        let paragraph = "<p>" + String(repeating: "A sentence of the published interview. ", count: 24) + "</p>"
        return "<html><head><title>The Art of Fiction No. 45</title></head><body>"
            + #"<div class="article-body-wrap"><main class="article-body">"#
            + String(repeating: paragraph, count: paragraphs)
            + "</main>"
            + #"<div class="paywall"><h1>Want to keep reading?</h1>"#
            + "<h4>Already a subscriber? Sign in below.</h4></div>"
            + "</div></body></html>"
    }

    private func bodyLength(of resolution: ArticleResolution) -> Int? {
        if case let .readable(content, _) = resolution { return content.bodyTextLength }
        return nil
    }

    /// NYT-shaped: Safari can apply the site rule's script-block half but cannot spoof
    /// the request UA, so the captured DOM is the publisher's TRUNCATED render and still
    /// declares a lock. The resolver must spend the one silent custom-UA fetch the rule
    /// describes and return that fuller body instead of the capture.
    func testTrustedCaptureStillLockedIsUpgradedBySilentSiteUnlock() async {
        let articleURL = URL(string: "https://www.nytimes.com/2026/07/24/science/enzymes.html")!
        let capture = truncatedLockedCaptureHTML()                     // ~2.1k chars, locked
        let fetcher = MockArticleFetcher()
        fetcher.htmlByURL[articleURL.absoluteString] = proseHTML("nyt-unlocked", paragraphs: 8)

        let result = await ArticleResolver.resolve(
            url: articleURL, page: .safariHandoff(html: capture), fetcher: fetcher)

        // The same capture with no reachable unlock resolves to the capture itself,
        // which gives the length to beat.
        let fallback = await ArticleResolver.resolve(
            url: articleURL, page: .safariHandoff(html: capture), fetcher: MockArticleFetcher())
        guard let unlocked = bodyLength(of: result), let captured = bodyLength(of: fallback) else {
            return XCTFail("expected readable results, got \(result) / \(fallback)")
        }
        XCTAssertGreaterThan(unlocked, captured, "the silent unlock must win over the truncated capture")
        // It used NYT's rule: a custom crawler User-Agent, not a plain re-fetch.
        let uaCall = fetcher.calls.first { $0.kind == .userAgent }
        XCTAssertEqual(uaCall?.userAgent, "Mozilla/5.0 (compatible; Google-InspectionTool/1.0)")
    }

    /// The capture is never LOST: when the rule's silent fetch fails outright, the
    /// resolver hands back the page the user is looking at rather than parking it.
    func testTrustedCaptureSurvivesAFailedSiteUnlock() async {
        let articleURL = URL(string: "https://www.nytimes.com/2026/07/24/science/enzymes.html")!
        let capture = truncatedLockedCaptureHTML()
        let fetcher = MockArticleFetcher()          // every fetch throws (no stubs)

        let result = await ArticleResolver.resolve(
            url: articleURL, page: .safariHandoff(html: capture), fetcher: fetcher)

        if case let .readable(_, html) = result {
            XCTAssertEqual(html, capture)
        } else {
            XCTFail("a failed unlock must fall back to the capture, got \(result)")
        }
        XCTAssertTrue(fetcher.calls.contains { $0.kind == .userAgent }, "the rule leg should have been tried")
    }

    /// Never trade DOWN: a rule fetch can be readable (no lock, over the threshold) and
    /// still be shorter than what the user already had on screen.
    func testTrustedCaptureIsNotTradedDownForAShorterUnlock() async {
        let articleURL = URL(string: "https://www.nytimes.com/2026/07/24/science/enzymes.html")!
        let capture = truncatedLockedCaptureHTML()                     // ~2.1k chars, locked
        let fetcher = MockArticleFetcher()
        fetcher.htmlByURL[articleURL.absoluteString] = proseHTML("nyt-teaser", paragraphs: 1)

        let result = await ArticleResolver.resolve(
            url: articleURL, page: .safariHandoff(html: capture), fetcher: fetcher)

        if case let .readable(_, html) = result {
            XCTAssertEqual(html, capture, "the longer capture must be kept")
        } else {
            XCTFail("expected readable, got \(result)")
        }
    }

    /// A host with no site-unlock rule still gets the silent ARCHIVE tier: a body the
    /// server truncated is one thing the browser provably could not fix, and a
    /// pre-paywall capture can. The capture is kept when nothing beats it, and the
    /// attempt costs exactly the two Wayback probes — no re-fetch of the page itself.
    func testTrustedCaptureOnRuleFreeHostStillTriesTheArchives() async {
        let articleURL = URL(string: "https://www.example-blog-host.com/2026/07/post")!
        XCTAssertNil(SiteUnlockRules.rule(for: articleURL), "fixture host must carry no unlock rule")
        let capture = truncatedLockedCaptureHTML()
        let fetcher = MockArticleFetcher()

        let result = await ArticleResolver.resolve(
            url: articleURL, page: .safariHandoff(html: capture), fetcher: fetcher)

        if case let .readable(_, html) = result {
            XCTAssertEqual(html, capture)
        } else {
            XCTFail("expected readable, got \(result)")
        }
        // Exactly the two Wayback probes and nothing else — no re-fetch of the page.
        // The tier runs them concurrently, so compare as a SET, not a sequence.
        XCTAssertEqual(Set(fetcher.calls.map(\.kind)), [.waybackRaw, .waybackPrePaywall])
        XCTAssertEqual(fetcher.calls.count, 2)
    }

    /// The Paris Review case end to end: the live page serves a long readable preview cut
    /// off server-side, the NEWEST Wayback capture carries the same wall, and the OLDEST
    /// one predates the paywall entirely. The resolver must walk past the truncated
    /// capture and return the pre-paywall body.
    func testPrePaywallCaptureBeatsATruncatedPreview() async {
        let articleURL = URL(string: "https://www.theparisreview.org/interviews/3810/steinbeck")!
        let fetcher = MockArticleFetcher()
        fetcher.htmlByURL[articleURL.absoluteString] = truncatedPreviewHTML(paragraphs: 20)
        fetcher.prePaywallHTMLByURL[articleURL.absoluteString] = proseHTML("steinbeck", paragraphs: 40)

        let result = await ArticleResolver.resolve(url: articleURL, fetcher: fetcher)

        guard case let .readable(content, _) = result else {
            return XCTFail("expected readable, got \(result)")
        }
        XCTAssertTrue(content.title.contains("steinbeck"), "the pre-paywall capture must win")
        // The direct read is still first; the silent tier behind it fans out, so its two
        // Wayback probes are compared as a set.
        XCTAssertEqual(fetcher.calls.first?.kind, .plain)
        XCTAssertEqual(Set(fetcher.calls.dropFirst().map(\.kind)), [.waybackRaw, .waybackPrePaywall])
    }

    /// Same shape, but the archives only ever hold the walled version: the item parks for
    /// the browser tier under its real title rather than silently saving the preview.
    func testTruncatedPreviewWithNoPrePaywallCaptureParks() async {
        let articleURL = URL(string: "https://www.theparisreview.org/interviews/3810/steinbeck")!
        let fetcher = MockArticleFetcher()
        fetcher.htmlByURL[articleURL.absoluteString] = truncatedPreviewHTML(paragraphs: 20)

        let result = await ArticleResolver.resolve(url: articleURL, fetcher: fetcher)

        XCTAssertEqual(result, .paywalled(title: "The Art of Fiction No. 45"))
    }

    /// When EVERY silent strategy fails (no readable result anywhere) on a host that
    /// carries a title, the resolver parks it as `.paywalled(title)` — it does NOT
    /// stop early or return readable. The archive fallback also fails here.
    func testResolverFallsAllTheWayToPaywalledWhenEveryStrategyFails() async {
        let articleURL = URL(string: "https://www.wsj.com/articles/secret_199845b1.html")!
        let fetcher = MockArticleFetcher()
        // Direct returns a titled locked teaser; every silent strategy + archive fail.
        fetcher.htmlByURL[articleURL.absoluteString] =
            "<html><head><title>WSJ Story</title></head><body><p>Lede only. Subscribe to read.</p></body></html>"
        let result = await ArticleResolver.resolve(url: articleURL, fetcher: fetcher)
        // WSJ's title survives; the body never became readable.
        XCTAssertEqual(result, .paywalled(title: "WSJ Story"))
    }

    // MARK: - The silent tier runs concurrently but resolves by plan order

    /// The load-bearing invariant of the concurrent silent tier: a lower-ranked strategy
    /// that answers FIRST must not beat a higher-ranked one that is still in flight.
    /// Here the Paris Review shape is inverted — the pre-paywall capture (ranked last)
    /// returns instantly while the newest capture (ranked ahead of it) takes a moment —
    /// and the newest capture must still win, exactly as it did when the tier walked its
    /// strategies one at a time.
    func testSlowerHigherRankedStrategyStillWins() async {
        let articleURL = URL(string: "https://www.theparisreview.org/interviews/3810/steinbeck")!
        let fetcher = MockArticleFetcher()
        fetcher.htmlByURL[articleURL.absoluteString] = truncatedPreviewHTML(paragraphs: 20)
        // Both archive captures are readable. The newest (ranked first) takes a beat;
        // the oldest (ranked last) answers instantly.
        fetcher.waybackHTMLByURL[articleURL.absoluteString] = proseHTML("newest", paragraphs: 40)
        fetcher.prePaywallHTMLByURL[articleURL.absoluteString] = proseHTML("oldest", paragraphs: 40)
        fetcher.delaysByKind = [.waybackRaw: 0.25]

        let result = await ArticleResolver.resolve(url: articleURL, fetcher: fetcher)

        guard case let .readable(content, _) = result else {
            return XCTFail("expected readable, got \(result)")
        }
        XCTAssertTrue(content.title.contains("newest"),
                      "the instant lower-ranked capture must not outrank the slower first choice")
    }

    /// And the tier really is concurrent: two strategies that each take a beat finish in
    /// about ONE beat, not two. This is the whole reason a hard-paywalled save stopped
    /// looking hung — serially the same page spent the sum of every strategy's latency.
    func testSilentStrategiesRunConcurrently() async {
        let articleURL = URL(string: "https://www.theparisreview.org/interviews/3810/nothing-works")!
        let fetcher = MockArticleFetcher()
        // Nothing is readable, so the tier must wait for BOTH probes before parking.
        fetcher.htmlByURL[articleURL.absoluteString] = truncatedPreviewHTML(paragraphs: 20)
        fetcher.delaysByKind = [.waybackRaw: 0.4, .waybackPrePaywall: 0.4]

        let start = Date()
        _ = await ArticleResolver.resolve(url: articleURL, fetcher: fetcher)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(Set(fetcher.calls.dropFirst().map(\.kind)), [.waybackRaw, .waybackPrePaywall])
        XCTAssertLessThan(elapsed, 0.7, "0.4s + 0.4s of independent fetches must overlap, not add up")
    }

    /// A winner must not be held hostage by the losers it made unnecessary. This is the
    /// specific trap that bit the Wayback index race: `withTaskGroup` implicitly awaits
    /// every child before returning, so a tier that "returns early" can still sit on a
    /// slow sibling unless cancellation actually reaches its request. Here the
    /// first-ranked capture is readable and instant while the second-ranked one takes
    /// two seconds — the resolve must come back in well under that.
    func testAWinnerDoesNotWaitForTheStrategiesItMadeUnnecessary() async {
        let articleURL = URL(string: "https://www.theparisreview.org/interviews/3810/quick-win")!
        let fetcher = MockArticleFetcher()
        fetcher.htmlByURL[articleURL.absoluteString] = truncatedPreviewHTML(paragraphs: 20)
        fetcher.waybackHTMLByURL[articleURL.absoluteString] = proseHTML("newest", paragraphs: 40)
        fetcher.delaysByKind = [.waybackPrePaywall: 2.0]

        let start = Date()
        let result = await ArticleResolver.resolve(url: articleURL, fetcher: fetcher)
        let elapsed = Date().timeIntervalSince(start)

        guard case let .readable(content, _) = result else {
            return XCTFail("expected readable, got \(result)")
        }
        XCTAssertTrue(content.title.contains("newest"))
        XCTAssertLessThan(elapsed, 1.0, "the cancelled loser must not hold the tier open")
    }

    // MARK: - Subscribe-redirect hosts (News Corp Australia)

    private var newsCorpArticle: URL {
        URL(string: "https://www.theaustralian.com.au/wealth/retirement/"
            + "selffunded-retirees-hit-by-new-30pc-topup-tax-on-investments/news-story/"
            + "476176fcef46250d229a1612ce9f44d1")!
    }

    /// The whole reported bug, end to end: the direct read is refused as a subscribe
    /// redirect, and the `?amp` rendering — which the same site DOESN'T redirect —
    /// carries the full body, so the save lands readable with no browser, no archive
    /// and no CAPTCHA.
    func testSubscribeRedirectIsRecoveredByTheAMPQueryFetch() async {
        let fetcher = MockArticleFetcher()
        fetcher.fetchErrorsByURL[newsCorpArticle.absoluteString] =
            .subscribeRedirect(landedOn: URL(string:
                "https://www.theaustralian.com.au/subscribe/news/1/?dest=x")!)
        fetcher.htmlByURL[newsCorpArticle.absoluteString + "?amp"] =
            BypassFixtures.html("Readable/theaustralian-amp.html")

        let result = await ArticleResolver.resolve(url: newsCorpArticle, fetcher: fetcher)

        if case let .readable(content, _) = result {
            XCTAssertGreaterThan(content.bodyTextLength, 2500)
            XCTAssertTrue(content.wholeText.contains("top-up tax"))
        } else {
            XCTFail("expected the AMP rendering to be readable, got \(result)")
        }
    }

    /// And when even the AMP fetch fails, the item parks with the redirect's own
    /// reason — never with the subscription pitch as its body.
    func testSubscribeRedirectWithNoAMPRecoveryParksWithItsReason() async {
        let fetcher = MockArticleFetcher()
        let landing = URL(string: "https://www.theaustralian.com.au/subscribe/news/1/?dest=x")!
        fetcher.fetchErrorsByURL[newsCorpArticle.absoluteString] =
            .subscribeRedirect(landedOn: landing)
        fetcher.fetchErrorsByURL[newsCorpArticle.absoluteString + "?amp"] =
            .subscribeRedirect(landedOn: landing)

        let result = await ArticleResolver.resolve(url: newsCorpArticle, fetcher: fetcher)

        XCTAssertEqual(result, .unreadable(.subscribeRedirect))
    }
}

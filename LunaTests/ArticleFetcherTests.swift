//
//  ArticleFetcherTests.swift
//  LunaTests
//

@testable import LunaFetch
import XCTest
@testable import Luna

final class ArticleFetcherTests: XCTestCase {

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            fatalError("test URL string is malformed: \(string)")
        }
        return url
    }

    // MARK: - archive.today detection / unwrapping

    func testIsArchiveTodayURLAcrossRotatingDomains() {
        for host in ["archive.is", "archive.ph", "archive.md", "archive.today", "archive.vn"] {
            XCTAssertTrue(ArticleFetcher.isArchiveTodayURL(url("https://\(host)/abc123")))
        }
        XCTAssertFalse(ArticleFetcher.isArchiveTodayURL(url("https://www.wsj.com/tech/story")))
    }

    func testOriginalURLExtractedFromTimestampedSnapshot() {
        let archive = url("https://archive.is/20260618194916/https://www.ft.com/content/d4f89b6b-c213")
        XCTAssertEqual(
            ArticleFetcher.originalURL(fromArchiveURL: archive),
            url("https://www.ft.com/content/d4f89b6b-c213"))
    }

    func testOriginalURLExtractedFromNewestSnapshot() {
        let archive = url("https://archive.ph/newest/https://www.wsj.com/tech/apple-199845b1")
        XCTAssertEqual(
            ArticleFetcher.originalURL(fromArchiveURL: archive),
            url("https://www.wsj.com/tech/apple-199845b1"))
    }

    func testOriginalURLNilForBareSnapshotID() {
        XCTAssertNil(ArticleFetcher.originalURL(fromArchiveURL: url("https://archive.is/Po8Hk")))
    }

    func testCanonicalUnwrapsArchiveURLAndStripsTracking() {
        let archive = url("https://archive.is/2026/https://www.wsj.com/tech/apple-199845b1?mod=mhp")
        // Unwraps to the original AND drops the tracking param.
        XCTAssertEqual(
            ArticleFetcher.canonicalForArchiving(archive),
            url("https://www.wsj.com/tech/apple-199845b1"))
    }

    // MARK: - hard-paywall hosts

    func testNYTimesNetworkRequestUsesRootDottedHostWithoutChangingOtherSites() {
        let article = url("https://www.nytimes.com/2026/09/29/us/story.html?source=share")
        XCTAssertEqual(
            ArticleFetcher.networkRequestURL(for: article).absoluteString,
            "https://www.nytimes.com./2026/09/29/us/story.html?source=share")
        XCTAssertEqual(
            ArticleFetcher.networkRequestURL(for: url("https://www.wsj.com/story")).absoluteString,
            "https://www.wsj.com/story")
        XCTAssertEqual(
            ArticleFetcher.networkRequestURL(for: url("https://www.nytimes.com./story")).absoluteString,
            "https://www.nytimes.com./story")
    }

    func testHardPaywallHostMatchesDomainAndSubdomain() {
        XCTAssertTrue(ArticleFetcher.isHardPaywallHost(url("https://www.wsj.com/tech/x")))
        XCTAssertTrue(ArticleFetcher.isHardPaywallHost(url("https://ft.com/content/x")))
        XCTAssertTrue(ArticleFetcher.isHardPaywallHost(url("https://www.nytimes.com/2026/x")))
        XCTAssertFalse(ArticleFetcher.isHardPaywallHost(url("https://www.theverge.com/x")))
        // Must not match a lookalike suffix that isn't a real subdomain boundary.
        XCTAssertFalse(ArticleFetcher.isHardPaywallHost(url("https://notwsj.com/x")))
    }

    // MARK: - placeholder title guess

    func testTitleGuessHumanizesSlugAndDropsIDToken() {
        let guess = ArticleFetcher.articleTitleGuess(
            from: url("https://www.wsj.com/tech/apple-price-increases-memory-supply-199845b1"))
        XCTAssertEqual(guess, "Apple Price Increases Memory Supply")
    }

    func testTitleGuessUnwrapsArchiveURLFirst() {
        let guess = ArticleFetcher.articleTitleGuess(
            from: url("https://archive.is/2026/https://www.wsj.com/tech/big-chip-shortage-deepens"))
        XCTAssertEqual(guess, "Big Chip Shortage Deepens")
    }

    // MARK: - Memento TimeMap parsing

    func testNewestMementoPrefersLastMementoEntry() {
        let timeMap = """
        <http://archive.is/timemap/https://www.wsj.com/x>;rel="self";type="application/link-format",
        <https://www.wsj.com/x>;rel="original",
        <https://archive.ph/abc11>;rel="first memento";datetime="Mon, 01 Jan 2024 00:00:00 GMT",
        <https://archive.ph/def22>;rel="memento";datetime="Wed, 05 Mar 2025 12:00:00 GMT",
        <https://archive.ph/xyz99>;rel="last memento";datetime="Tue, 18 Jun 2026 23:28:44 GMT"
        """
        XCTAssertEqual(ArticleFetcher.newestMemento(fromTimeMap: timeMap), url("https://archive.ph/xyz99"))
    }

    func testNewestMementoFallsBackToLastListedWhenNoExplicitLast() {
        let timeMap = """
        <https://archive.ph/abc11>;rel="first memento";datetime="Mon, 01 Jan 2024 00:00:00 GMT",
        <https://archive.ph/def22>;rel="memento";datetime="Wed, 05 Mar 2025 12:00:00 GMT"
        """
        XCTAssertEqual(ArticleFetcher.newestMemento(fromTimeMap: timeMap), url("https://archive.ph/def22"))
    }

    func testNewestMementoNilForNonTimeMapOrChallengeHTML() {
        XCTAssertNil(ArticleFetcher.newestMemento(fromTimeMap: "<html><body>Why do I have to complete a CAPTCHA</body></html>"))
        XCTAssertNil(ArticleFetcher.newestMemento(fromTimeMap: ""))
    }

    // MARK: - Subscribe-interstitial redirects

    /// The live regression: a premium News Corp article answers a plain GET with a
    /// 302 chain that ends on the publisher's own subscribe page. It's a 200 with a
    /// long body, so nothing downstream can tell it isn't the article — the FETCH has
    /// to fail instead.
    func testArticleRedirectedToSubscribePageIsReportedAsSuch() {
        let article = url("https://www.theaustralian.com.au/wealth/retirement/story/news-story/abc")
        let interstitial = url(
            "https://www.theaustralian.com.au/subscribe/news/1/?dest=https%3A%2F%2Fwww."
            + "theaustralian.com.au%2Fwealth%2Fretirement%2Fstory%2Fnews-story%2Fabc"
            + "&memtype=anonymous&mode=premium")
        XCTAssertEqual(
            ArticleFetcher.subscribeRedirectLanding(requested: article, finalURL: interstitial),
            interstitial)
    }

    /// The `/remote/check_cookie.html?url=…` bounce the same publishers serve counts
    /// too — it is equally not the article.
    func testCookieCheckBounceCounts() {
        let article = url("https://www.heraldsun.com.au/news/story/news-story/abc")
        let bounce = url("https://www.heraldsun.com.au/remote/check_cookie.html?url=x")
        XCTAssertEqual(
            ArticleFetcher.subscribeRedirectLanding(requested: article, finalURL: bounce), bounce)
    }

    /// No redirect, no substitution: the page we asked for came back.
    func testUnredirectedResponseIsNotASubscribeRedirect() {
        let article = url("https://www.theaustralian.com.au/news/story/news-story/abc")
        XCTAssertNil(
            ArticleFetcher.subscribeRedirectLanding(requested: article, finalURL: article))
        XCTAssertNil(ArticleFetcher.subscribeRedirectLanding(requested: article, finalURL: nil))
    }

    /// A redirect to another ARTICLE (a canonicalizing 301) is normal and must pass.
    func testRedirectToOrdinaryPageIsNotASubscribeRedirect() {
        XCTAssertNil(ArticleFetcher.subscribeRedirectLanding(
            requested: url("https://example.com/story"),
            finalURL: url("https://example.com/2026/07/story")))
    }

    /// Asking FOR a subscribe page (the user saved one, or an archive replay of one)
    /// still fetches: the guard only catches a page being substituted for the article.
    func testRequestingAnInterstitialIsNotItselfARedirect() {
        let interstitial = url("https://www.theaustralian.com.au/subscribe/news/1/?x=1")
        XCTAssertNil(ArticleFetcher.subscribeRedirectLanding(
            requested: interstitial,
            finalURL: url("https://www.theaustralian.com.au/subscribe/news/1/?x=1&nk=2")))
    }

    func testTitleGuessFallsBackToHostWhenSlugIsOpaque() {
        // FT content URLs are bare UUIDs — no humanizable slug, so fall back to host.
        let guess = ArticleFetcher.articleTitleGuess(
            from: url("https://www.ft.com/content/d4f89b6b-c213-4550-924b-a9ae45e24c37"))
        XCTAssertEqual(guess, "ft.com")
    }
}

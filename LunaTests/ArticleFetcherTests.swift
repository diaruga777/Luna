//
//  ArticleFetcherTests.swift
//  LunaTests
//

import LunaFetch
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

    func testTitleGuessFallsBackToHostWhenSlugIsOpaque() {
        // FT content URLs are bare UUIDs — no humanizable slug, so fall back to host.
        let guess = ArticleFetcher.articleTitleGuess(
            from: url("https://www.ft.com/content/d4f89b6b-c213-4550-924b-a9ae45e24c37"))
        XCTAssertEqual(guess, "ft.com")
    }
}

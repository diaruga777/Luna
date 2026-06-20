//
//  BypassServiceURLTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

/// Covers the value mappings: crawler UA/XFF, referer origins, and the third-party
/// service URL builders (the verified request formats).
final class BypassServiceURLTests: XCTestCase {

    private let article = URL(string: "https://www.wsj.com/articles/markets-1234?mod=hp")!

    // MARK: - Crawler agents

    func testCrawlerUserAgents() {
        XCTAssertTrue(CrawlerAgent.googlebotDesktop.userAgent.contains("Googlebot/2.1"))
        XCTAssertTrue(CrawlerAgent.googlebotMobile.userAgent.contains("Googlebot/2.1"))
        XCTAssertTrue(CrawlerAgent.googlebotMobile.userAgent.contains("Mobile"))
        XCTAssertTrue(CrawlerAgent.bingbot.userAgent.contains("bingbot/2.0"))
    }

    func testCrawlerXFF() {
        XCTAssertEqual(CrawlerAgent.googlebotDesktop.xForwardedFor, "66.249.66.1")
        XCTAssertEqual(CrawlerAgent.googlebotMobile.xForwardedFor, "66.249.66.1")
        XCTAssertNil(CrawlerAgent.bingbot.xForwardedFor)
    }

    // MARK: - Referer origins

    func testRefererURLs() {
        XCTAssertEqual(RefererOrigin.google.url, "https://www.google.com/")
        XCTAssertEqual(RefererOrigin.facebook.url, "https://www.facebook.com/")
        XCTAssertEqual(RefererOrigin.twitter.url, "https://t.co/")
    }

    // MARK: - Ladder proxy (silent)

    func testOneFtPrefixesRawURL() {
        XCTAssertEqual(
            LadderProxy.oneFt.url(for: article)?.absoluteString,
            "https://1ft.io/https://www.wsj.com/articles/markets-1234?mod=hp")
    }

    // MARK: - Third-party web services

    func testSmryPrefixesRawURL() {
        XCTAssertEqual(
            ThirdPartyWebService.smry.url(for: article)?.absoluteString,
            "https://smry.ai/https://www.wsj.com/articles/markets-1234?mod=hp")
    }

    func testRemovePaywallsPrefixesRawURL() {
        XCTAssertEqual(
            ThirdPartyWebService.removePaywalls.url(for: article)?.absoluteString,
            "https://removepaywalls.com/https://www.wsj.com/articles/markets-1234?mod=hp")
    }

    func testRemovePaywallEncodesURLQueryParam() {
        let result = ThirdPartyWebService.removePaywall.url(for: article)?.absoluteString
        XCTAssertEqual(
            result,
            "https://www.removepaywall.com/search?url=https%3A%2F%2Fwww.wsj.com%2Farticles%2Fmarkets-1234%3Fmod%3Dhp")
    }

    func testStrategyRunsSilentlyClassification() {
        XCTAssertTrue(BypassStrategy.waybackRaw.runsSilently)
        XCTAssertTrue(BypassStrategy.ladderProxy(.oneFt).runsSilently)
        XCTAssertTrue(BypassStrategy.jsonLDBody.runsSilently)
        XCTAssertFalse(BypassStrategy.thirdPartyWeb(.smry).runsSilently)
        XCTAssertFalse(BypassStrategy.archiveToday.runsSilently)
    }
}

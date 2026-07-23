//
//  BypassRunnerTests.swift
//  LunaTests
//

import LunaArticleIngest
import LunaPaywallBypass
import LunaFetch
import XCTest
@testable import Luna

/// Exercises `BypassRunner` against a mock `HTMLFetching`: asserts each strategy
/// calls the right fetch with the right UA / referer / XFF / URL, and that the
/// WKWebView-only strategies return nil (not silent).
final class BypassRunnerTests: XCTestCase {

    private let articleURL = URL(string: "https://www.example.com/news/story")!
    private var fetcher: MockArticleFetcher!
    private var runner: BypassRunner!

    /// A long readable body so extraction clears the readability gate.
    private func readableHTML(_ marker: String = "body") -> String {
        let paragraph = "<p>" + String(repeating: "An ordinary readable sentence about the topic. ", count: 30) + "</p>"
        return "<html><head><title>Real Story \(marker)</title></head><body><article>\(paragraph)\(paragraph)</article></body></html>"
    }

    override func setUp() {
        super.setUp()
        fetcher = MockArticleFetcher()
        runner = BypassRunner(fetcher: fetcher)
    }

    func testUserAgentStrategySendsCrawlerUAAndXFF() async {
        fetcher.htmlByURL[articleURL.absoluteString] = readableHTML()
        let result = await runner.run(.userAgent(.googlebotDesktop), url: articleURL, directHTML: nil)
        XCTAssertNotNil(result)
        let call = fetcher.calls.first
        XCTAssertEqual(call?.kind, .userAgent)
        XCTAssertEqual(call?.userAgent, CrawlerAgent.googlebotDesktop.userAgent)
        XCTAssertEqual(call?.xForwardedFor, "66.249.66.1")
    }

    func testBingbotStrategyOmitsXFF() async {
        fetcher.htmlByURL[articleURL.absoluteString] = readableHTML()
        _ = await runner.run(.userAgent(.bingbot), url: articleURL, directHTML: nil)
        XCTAssertEqual(fetcher.calls.first?.userAgent, CrawlerAgent.bingbot.userAgent)
        XCTAssertNil(fetcher.calls.first?.xForwardedFor)
    }

    func testRefererStrategySendsReferer() async {
        fetcher.htmlByURL[articleURL.absoluteString] = readableHTML()
        _ = await runner.run(.referer(.twitter), url: articleURL, directHTML: nil)
        XCTAssertEqual(fetcher.calls.first?.kind, .referer)
        XCTAssertEqual(fetcher.calls.first?.referer, "https://t.co/")
    }

    func testTrailingDotFetchesDottedHostButKeepsCanonicalBase() async {
        let dotted = URL(string: "https://www.example.com./news/story")!
        fetcher.htmlByURL[dotted.absoluteString] = readableHTML()
        let result = await runner.run(.trailingDotHost, url: articleURL, directHTML: nil)
        XCTAssertNotNil(result)
        XCTAssertEqual(fetcher.calls.first?.url, dotted)
    }

    func testFreshSessionUsesNoCookies() async {
        fetcher.htmlByURL[articleURL.absoluteString] = readableHTML()
        _ = await runner.run(.freshSession, url: articleURL, directHTML: nil)
        XCTAssertEqual(fetcher.calls.first?.kind, .freshSession)
        XCTAssertEqual(fetcher.calls.first?.noCookies, true)
    }

    func testWaybackRawStrategy() async {
        fetcher.htmlByURL[articleURL.absoluteString] = readableHTML()
        _ = await runner.run(.waybackRaw, url: articleURL, directHTML: nil)
        XCTAssertEqual(fetcher.calls.first?.kind, .waybackRaw)
    }

    func testJinaReaderStrategy() async {
        fetcher.htmlByURL[articleURL.absoluteString] = readableHTML()
        _ = await runner.run(.jinaReader, url: articleURL, directHTML: nil)
        XCTAssertEqual(fetcher.calls.first?.kind, .jina)
    }

    func testLadderProxyFetchesProxyURL() async {
        let proxyURL = LadderProxy.oneFt.url(for: articleURL)!
        fetcher.htmlByURL[proxyURL.absoluteString] = readableHTML()
        let result = await runner.run(.ladderProxy(.oneFt), url: articleURL, directHTML: nil)
        XCTAssertNotNil(result)
        XCTAssertEqual(fetcher.calls.first?.url, proxyURL)
        XCTAssertEqual(fetcher.calls.first?.kind, .plain)
    }

    func testAMPFollowsDiscoveredURL() async {
        let ampURL = URL(string: "https://www.example.com/news/story/amp")!
        let directHTML = "<html><head><link rel=\"amphtml\" href=\"\(ampURL.absoluteString)\"></head><body></body></html>"
        fetcher.htmlByURL[ampURL.absoluteString] = readableHTML("amp")
        let result = await runner.run(.amp, url: articleURL, directHTML: directHTML)
        XCTAssertNotNil(result)
        XCTAssertEqual(fetcher.calls.first?.url, ampURL)
    }

    func testAMPWithoutLinkReturnsNilAndDoesNotFetch() async {
        let result = await runner.run(.amp, url: articleURL, directHTML: "<html><body></body></html>")
        XCTAssertNil(result)
        XCTAssertTrue(fetcher.calls.isEmpty)
    }

    func testJSONLDBodyIsZeroNetwork() async {
        let html = BypassFixtures.html("jsonld-bloomberg.html")
        let result = await runner.run(.jsonLDBody, url: articleURL, directHTML: html)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.content.bodyTextLength > 600)
        XCTAssertTrue(fetcher.calls.isEmpty, "JSON-LD recovery must not hit the network")
    }

    func testArchiveTodayIsNotSilent() async {
        let archive = await runner.run(.archiveToday, url: articleURL, directHTML: nil)
        XCTAssertNil(archive)
        XCTAssertTrue(fetcher.calls.isEmpty)
    }

    func testFetchFailureFallsThroughToNil() async {
        fetcher.failingURLs.insert(articleURL.absoluteString)
        let result = await runner.run(.waybackRaw, url: articleURL, directHTML: nil)
        XCTAssertNil(result)
    }
}

//
//  SiteUnlockSilentTests.swift
//  LunaTests
//

import LunaPaywallBypass
import XCTest

/// The silent (URLSession) unlock leg: each rule maps to the right request transform,
/// and the dispatch calls the matching `HTMLFetching` primitive.
final class SiteUnlockSilentTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(string: s)! }
    private func rule(_ host: String) -> SiteUnlockRule {
        SiteUnlockRules.rule(for: url("https://www.\(host)/x"))!
    }

    func testWSJMapsToDrudgeReferer() {
        XCTAssertEqual(SiteUnlockSilent.fetchKind(for: rule("wsj.com")),
                       .referer("https://www.drudgereport.com/"))
    }

    func testGooglebotSiteMapsToCrawlerUAWithXFF() {
        // businessinsider.com uses useragent: googlebot.
        XCTAssertEqual(
            SiteUnlockSilent.fetchKind(for: rule("businessinsider.com")),
            .userAgent("Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
                       xForwardedFor: "66.249.66.1"))
    }

    func testNYTMapsToCustomInspectionToolUA() {
        XCTAssertEqual(SiteUnlockSilent.fetchKind(for: rule("nytimes.com")),
                       .userAgent("Mozilla/5.0 (compatible; Google-InspectionTool/1.0)", xForwardedFor: nil))
    }

    func testFinancialTimesMapsToGoogleReferer() {
        XCTAssertEqual(SiteUnlockSilent.fetchKind(for: rule("ft.com")), .referer("https://www.google.com/"))
    }

    func testScriptBlockOnlySiteHasNoSilentTechnique() {
        // The Atlantic uses only block_regex (+ allow_cookies) — a browser-tier site.
        XCTAssertEqual(SiteUnlockSilent.fetchKind(for: rule("theatlantic.com")), .none)
    }

    func testDispatchCallsRefererPrimitiveForWSJ() async throws {
        let target = url("https://www.wsj.com/finance/x-c609beb1")
        let mock = MockArticleFetcher()
        mock.htmlByURL[target.absoluteString] = "<html><body>full article</body></html>"
        let html = try await SiteUnlockSilent.fetch(url: target, rule: rule("wsj.com"), fetcher: mock)
        XCTAssertEqual(html, "<html><body>full article</body></html>")
        XCTAssertEqual(mock.calls.count, 1)
        XCTAssertEqual(mock.calls.first?.kind, .referer)
        XCTAssertEqual(mock.calls.first?.referer, "https://www.drudgereport.com/")
    }

    func testDispatchCallsUserAgentPrimitiveForGooglebotSite() async throws {
        let target = url("https://www.businessinsider.com/x")
        let mock = MockArticleFetcher()
        mock.htmlByURL[target.absoluteString] = "<html><body>bi</body></html>"
        _ = try await SiteUnlockSilent.fetch(url: target, rule: rule("businessinsider.com"), fetcher: mock)
        XCTAssertEqual(mock.calls.first?.kind, .userAgent)
        XCTAssertEqual(mock.calls.first?.xForwardedFor, "66.249.66.1")
    }
}

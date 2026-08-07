//
//  SiteUnlockTests.swift
//  LunaTests
//

import LunaArchiveReader
import LunaPaywallBypass
import WebKit
import XCTest
@testable import Luna

/// Site paywall-unlock coverage: the WKContentRuleList-driven blocker JSON (and its
/// JS-regex-to-content-rule-filter sanitizer), the ported per-site unlock rule table
/// (host/subdomain/group matching, regex validity), the silent (URLSession) fetch
/// dispatch each rule maps to, and the bespoke per-site DOM cleanup snippets.
final class SiteUnlockTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: - PaywallUnlockRules

    func testContentRuleListJSONIsValidArrayOfBlockRules() throws {
        // A site with block_regex + the global vendor blockers yields block rules.
        let data = Data(PaywallUnlockRules.contentRuleListJSON(for: url("https://www.theatlantic.com/x")).utf8)
        let parsed = try JSONSerialization.jsonObject(with: data)
        let rules = try XCTUnwrap(parsed as? [[String: Any]])
        XCTAssertGreaterThan(rules.count, 15)
        for rule in rules {
            let trigger = try XCTUnwrap(rule["trigger"] as? [String: Any])
            XCTAssertNotNil(trigger["url-filter"] as? String)
            let action = try XCTUnwrap(rule["action"] as? [String: Any])
            XCTAssertEqual(action["type"] as? String, "block")
        }
    }

    func testContentRuleListCompiles() {
        // WebKit compiles the JSON — proves every ported/sanitized url-filter is valid
        // WKContentRuleList regex. No network; purely local compilation.
        let expectation = expectation(description: "compile")
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "unlock-compile-test",
            encodedContentRuleList: PaywallUnlockRules.contentRuleListJSON(for: url("https://www.theatlantic.com/x"))
        ) { list, error in
            XCTAssertNotNil(list, "rule list failed to compile: \(String(describing: error))")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)
    }

    func testGeneralBlockersCompileForAnUnknownHost() {
        // Even a host with no site rule gets the global vendor blockers — they must
        // all sanitize to a compilable list.
        let expectation = expectation(description: "compile-general")
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "unlock-general-test",
            encodedContentRuleList: PaywallUnlockRules.contentRuleListJSON(for: url("https://randomblog.example/x"))
        ) { list, error in
            XCTAssertNotNil(list, "general blockers failed to compile: \(String(describing: error))")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)
    }

    func testUrlFiltersSanitizeAndExpand() {
        // \d and \w are converted to char classes; \/ to a literal slash.
        XCTAssertEqual(PaywallUnlockRules.urlFilters(fromJSRegexSource: "\\.foo\\.com\\/x\\d+"),
                       ["\\.foo\\.com/x[0-9]+"])
        // Alternation is EXPANDED into concrete filters (WKContentRuleList has no `|`).
        XCTAssertEqual(PaywallUnlockRules.urlFilters(fromJSRegexSource: "(cdn|loader)\\.x\\.com/a"),
                       ["cdn\\.x\\.com/a", "loader\\.x\\.com/a"])
        XCTAssertEqual(
            Set(PaywallUnlockRules.urlFilters(fromJSRegexSource: "(\\.zephr\\.com/z|/zephr/feature)")),
            Set(["\\.zephr\\.com/z", "/zephr/feature"]))
        // Unsupported constructs → dropped (empty).
        XCTAssertEqual(PaywallUnlockRules.urlFilters(fromJSRegexSource: "foo\\bbar"), [])   // \b
        XCTAssertEqual(PaywallUnlockRules.urlFilters(fromJSRegexSource: "a{2,3}"), [])       // {n,m}
    }

    func testCleanupScriptGuardsArchiveHostsAndTargetsPaywalls() {
        let js = PaywallUnlockRules.domCleanupScript
        XCTAssertTrue(js.contains("archive"))          // self-guards off the archive reader
        XCTAssertTrue(js.contains("paywall"))           // targets paywall containers
        XCTAssertTrue(js.contains("MutationObserver"))  // watches late wall hydration for page lifetime
        XCTAssertTrue(js.contains("data-src"))          // un-lazies images
        XCTAssertTrue(js.contains("subscriptions-section"))  // reveals AMP subscriber sections
        // A content wrapper that shares a paywall class (e.g. WSJ's `.paywall`
        // content container) must be REVEALED, not removed — else the unlocked
        // article is deleted with the "overlay".
        XCTAssertTrue(js.contains("articleChars"))      // content-vs-overlay guard
        XCTAssertTrue(js.contains("reveal"))            // un-hide instead of delete
    }

    // MARK: - SiteUnlockRules

    // Exercises the site paywall-unlock rule table (generated from the upstream
    // `sites.js` into the bundled `site_unlock_rules.json`): it loads, matches
    // hosts/subdomains/groups, and its ported regexes are valid. WSJ's rule must be the
    // current Referer→Drudge form, NOT the stale (now DataDome-blocked) Googlebot UA.

    func testTableLoaded() {
        XCTAssertGreaterThan(SiteUnlockRules.ruleCount, 500)
        XCTAssertGreaterThan(SiteUnlockRules.generalBlockers.count, 20)
    }

    func testWSJRuleIsRefererDrudge() throws {
        let rule = try XCTUnwrap(SiteUnlockRules.rule(for: url("https://www.wsj.com/articles/x-c609beb1")))
        XCTAssertEqual(rule.refererCustom, "https://www.drudgereport.com/")
        XCTAssertEqual(rule.allowCookies, true)
        XCTAssertEqual(rule.csDompurify, true)
        XCTAssertNil(rule.useragent)
        XCTAssertNil(rule.useragentCustom)
    }

    func testSubdomainAndBareHostBothMatchWSJ() {
        XCTAssertEqual(SiteUnlockRules.rule(for: url("https://wsj.com/x"))?.domain, "wsj.com")
        XCTAssertEqual(SiteUnlockRules.rule(for: url("https://www.wsj.com/x"))?.domain, "wsj.com")
        XCTAssertEqual(SiteUnlockRules.rule(for: url("https://edition.wsj.com/x"))?.domain, "wsj.com")
    }

    func testNYTUsesBlockRegexAndInspectionToolUA() throws {
        let rule = try XCTUnwrap(SiteUnlockRules.rule(for: url("https://www.nytimes.com/2026/07/01/x.html")))
        XCTAssertEqual(rule.useragentCustom, "Mozilla/5.0 (compatible; Google-InspectionTool/1.0)")
        XCTAssertFalse(rule.blockRegex?.isEmpty ?? true)
    }

    func testGroupMemberResolvesToGroupConfig() throws {
        // wired.com ships only via the Condé Nast group config (no standalone entry).
        let rule = try XCTUnwrap(SiteUnlockRules.rule(for: url("https://www.wired.com/story/x")))
        XCTAssertEqual(rule.domain, "wired.com")
        XCTAssertEqual(rule.allowCookies, true)
    }

    func testUnknownHostHasNoRule() {
        XCTAssertNil(SiteUnlockRules.rule(for: url("https://example.com/x")))
        XCTAssertNil(SiteUnlockRules.rule(for: url("https://news.ycombinator.com/x")))
    }

    func testFinancialTimesStripsCookies() throws {
        // FT has no allow_cookies — cookies ARE stripped there ("absence is meaningful").
        let rule = try XCTUnwrap(SiteUnlockRules.rule(for: url("https://www.ft.com/content/abc")))
        XCTAssertNil(rule.allowCookies)
        XCTAssertEqual(rule.referer, "google")
    }

    func testEveryPortedRegexCompiles() {
        var checked = 0
        func assertCompiles(_ pattern: String, _ label: String) {
            XCTAssertNoThrow(try NSRegularExpression(pattern: pattern), "bad regex for \(label): \(pattern)")
            checked += 1
        }
        for blocker in SiteUnlockRules.generalBlockers { assertCompiles(blocker.blockRegex, "general") }
        for host in ["nytimes.com", "bloomberg.com", "businessinsider.com", "theatlantic.com", "economist.com"] {
            if let rule = SiteUnlockRules.rule(for: url("https://www.\(host)/x")) {
                for pattern in rule.blockRegex ?? [] { assertCompiles(pattern, host) }
            }
        }
        XCTAssertGreaterThan(checked, 20)
    }

    func testNoFixDenylist() {
        XCTAssertFalse(SiteUnlockRules.isNoFix(url("https://www.economist.com/x")))
        XCTAssertTrue(SiteUnlockRules.isNoFix(url("https://www.nikkei.com/x")))
    }

    // MARK: - SiteUnlockSilent

    // The silent (URLSession) unlock leg: each rule maps to the right request transform,
    // and the dispatch calls the matching `HTMLFetching` primitive.

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

    // MARK: - SiteCleanupScripts

    // The bespoke per-site cleanup snippets (bundled JSON) load, match by
    // host/subdomain across the English + European news markets, and are self-contained
    // (no extension/cross-origin APIs that can't run in a plain WKWebView content world).

    /// A spread across regions confirmed present in the bundled set.
    private let sample = [
        "nytimes.com", "wsj.com", "bloomberg.com", "washingtonpost.com",     // US
        "lemonde.fr", "lefigaro.fr",                                          // FR
        "spiegel.de", "zeit.de",                                             // DE
        "elpais.com",                                                        // ES
        "corriere.it", "repubblica.it", "lastampa.it",                        // IT
        "telegraaf.nl", "nrc.nl",                                            // NL
        "aftenposten.no", "dn.se", "berlingske.dk",                           // Nordics
    ]

    func testBroadCoverageLoaded() {
        // Hundreds of domains across markets — a low floor catches a failed resource load.
        XCTAssertGreaterThan(SiteCleanupScripts.count, 500)
        for host in sample {
            XCTAssertNotNil(SiteCleanupScripts.script(for: url("https://www.\(host)/article")), host)
        }
    }

    func testUnknownHostHasNoSnippet() {
        XCTAssertNil(SiteCleanupScripts.script(for: url("https://example.com/x")))
        XCTAssertNil(SiteCleanupScripts.script(for: url("https://news.ycombinator.com/x")))
    }

    func testSubdomainMatches() {
        XCTAssertNotNil(SiteCleanupScripts.script(for: url("https://www.bloomberg.com/news/x")))
        XCTAssertNotNil(SiteCleanupScripts.script(for: url("https://edition.wsj.com/x")))
    }

    func testSampledSnippetsAreSelfContainedIIFEs() {
        let forbidden = ["chrome.", "browser.", "ext_api", "runtime.sendMessage",
                         "getArchive", "getExtSrc", "getExtFetch", "sendNativeMessage",
                         "replaceDomElementExt"]
        for host in sample {
            let js = SiteCleanupScripts.script(for: url("https://www.\(host)/x"))!
            XCTAssertTrue(js.hasPrefix("(function"), host)
            XCTAssertTrue(js.contains("try"), host)
            XCTAssertTrue(js.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(");"), host)
            for token in forbidden {
                XCTAssertFalse(js.contains(token), "\(host) uses forbidden \(token)")
            }
        }
    }
}

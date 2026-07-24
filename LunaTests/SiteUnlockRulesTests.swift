//
//  SiteUnlockRulesTests.swift
//  LunaTests
//

import LunaPaywallBypass
import XCTest

/// Exercises the site paywall-unlock rule table (generated from the upstream
/// `sites.js` into the bundled `site_unlock_rules.json`): it loads, matches
/// hosts/subdomains/groups, and its ported regexes are valid. WSJ's rule must be the
/// current Referer→Drudge form, NOT the stale (now DataDome-blocked) Googlebot UA.
final class SiteUnlockRulesTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(string: s)! }

    private func repositoryJSON(_ relativePath: String) throws -> Any {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(relativePath))
        return try JSONSerialization.jsonObject(with: data)
    }

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

    /// Safari can reproduce a site's script blocks but cannot reproduce its custom
    /// request User-Agent. Emitting only the block half broke NYT hydration: the
    /// server-rendered article painted, then the page blanked after its entitlement
    /// requests were blocked. Guard the checked-in generated artifact for every rule
    /// with that compound shape, not just NYT by name.
    func testSafariBlockerArtifactOmitsCustomUADependentSiteRules() throws {
        let source = try XCTUnwrap(
            repositoryJSON(
                "LunaLibraries/Sources/LunaPaywallBypass/Resources/site_unlock_rules.json")
                as? [String: Any])
        let sourceRules = try XCTUnwrap(source["rules"] as? [[String: Any]])
        let customUADomains = Set(sourceRules.compactMap { rule -> String? in
            guard rule["useragentCustom"] != nil,
                  !(rule["blockRegex"] as? [String] ?? []).isEmpty
            else { return nil }
            return rule["domain"] as? String
        })
        XCTAssertFalse(customUADomains.isEmpty)

        let generated = try XCTUnwrap(
            repositoryJSON("LunaSafari/Resources/rules_blockers.json")
                as? [[String: Any]])
        let generatedInitiators = Set(generated.flatMap { rule -> [String] in
            let condition = rule["condition"] as? [String: Any]
            return condition?["initiatorDomains"] as? [String] ?? []
        })

        XCTAssertTrue(
            customUADomains.isDisjoint(with: generatedInitiators),
            "Safari blocker emitted only the block half of a custom-UA unlock rule")
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
}

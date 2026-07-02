//
//  PaywallUnlockRulesTests.swift
//  LunaTests
//

import LunaArchiveReader
import LunaPaywallBypass
import WebKit
import XCTest
@testable import Luna

final class PaywallUnlockRulesTests: XCTestCase {
    private func url(_ s: String) -> URL { URL(string: s)! }

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
        XCTAssertTrue(js.contains("paywall"))           // removes paywall containers
        XCTAssertTrue(js.contains("setInterval"))       // re-runs over the poll window
        XCTAssertTrue(js.contains("data-src"))          // un-lazies images
        XCTAssertTrue(js.contains("subscriptions-section"))  // reveals AMP subscriber sections
    }
}

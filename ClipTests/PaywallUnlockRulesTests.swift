//
//  PaywallUnlockRulesTests.swift
//  ClipTests
//

import ClipArchiveReader
import ClipPaywallBypass
import WebKit
import XCTest
@testable import Clip

final class PaywallUnlockRulesTests: XCTestCase {
    private func url(_ s: String) -> URL { URL(string: s)! }

    func testContentRuleListJSONIsValidArrayOfBlockRules() throws {
        let data = Data(PaywallUnlockRules.contentRuleListJSON.utf8)
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
        // WebKit compiles the JSON — proves the regex/url-filter syntax is valid. No
        // network; purely local compilation.
        let expectation = expectation(description: "compile")
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "clip-paywall-test", encodedContentRuleList: PaywallUnlockRules.contentRuleListJSON
        ) { list, error in
            XCTAssertNotNil(list, "rule list failed to compile: \(String(describing: error))")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)
    }

    func testKnownPaywallHostMatchesApexAndSubdomains() {
        XCTAssertTrue(KnownPaywallHosts.isKnown(url("https://www.theatlantic.com/x")))
        XCTAssertTrue(KnownPaywallHosts.isKnown(url("https://wsj.com/x")))
        XCTAssertTrue(KnownPaywallHosts.isKnown(url("https://asia.nikkei.com/x")))
        XCTAssertFalse(KnownPaywallHosts.isKnown(url("https://randomblog.example/x")))
        // Must not match a lookalike suffix.
        XCTAssertFalse(KnownPaywallHosts.isKnown(url("https://notwsj.com/x")))
    }

    func testCleanupScriptGuardsArchiveHostsAndTargetsPaywalls() {
        let js = PaywallUnlockRules.domCleanupScript
        XCTAssertTrue(js.contains("archive"))          // self-guards off the archive reader
        XCTAssertTrue(js.contains("paywall"))           // removes paywall containers
        XCTAssertTrue(js.contains("setInterval"))       // re-runs over the poll window
        XCTAssertTrue(js.contains("data-src"))          // un-lazies images
    }
}

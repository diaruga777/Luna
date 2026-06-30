//
//  BypassRuleTableTests.swift
//  LuneTests
//

import LunePaywallBypass
import XCTest
@testable import Lune

/// Exercises the per-host rule lookup: apex + subdomain matching, unknown host,
/// and trailing-dot tolerance.
final class BypassRuleTableTests: XCTestCase {

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else { fatalError("bad test URL: \(string)") }
        return url
    }

    func testApexMatch() {
        XCTAssertEqual(BypassRuleTable.rule(for: url("https://wsj.com/articles/x"))?.domain, "wsj.com")
    }

    func testSubdomainMatch() {
        XCTAssertEqual(BypassRuleTable.rule(for: url("https://www.wsj.com/articles/x"))?.domain, "wsj.com")
        XCTAssertEqual(
            BypassRuleTable.rule(for: url("https://cooking.nytimes.com/r"))?.domain, "nytimes.com")
    }

    func testTrailingDotHostMatches() {
        XCTAssertEqual(BypassRuleTable.rule(for: url("https://www.wsj.com./articles/x"))?.domain, "wsj.com")
    }

    func testUnknownHostReturnsNil() {
        XCTAssertNil(BypassRuleTable.rule(for: url("https://example.com/x")))
    }

    func testLookalikeHostDoesNotMatch() {
        // A host that merely ends in the rule domain as a non-label suffix must not match.
        XCTAssertNil(BypassRuleTable.rule(for: url("https://notwsj.com/x")))
        XCTAssertNil(BypassRuleTable.rule(for: url("https://wsj.com.evil.example/x")))
    }

    func testEveryRuleEndsWithArchiveToday() {
        for rule in BypassRuleTable.rules {
            XCTAssertEqual(rule.strategies.last, .archiveToday, "\(rule.domain) must end in archiveToday")
        }
    }
}

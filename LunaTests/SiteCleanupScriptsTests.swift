//
//  SiteCleanupScriptsTests.swift
//  LunaTests
//

import LunaArchiveReader
import XCTest

/// The bespoke per-site cleanup snippets are present for the covered sites, match by
/// host/subdomain, and are self-contained (no extension/cross-origin APIs that can't
/// run in a plain WKWebView content world).
final class SiteCleanupScriptsTests: XCTestCase {
    private func url(_ s: String) -> URL { URL(string: s)! }

    private let covered = [
        "nytimes.com", "washingtonpost.com", "businessinsider.com", "theatlantic.com",
        "economist.com", "politico.com", "newstatesman.com", "telegraph.co.uk",
        "aftenposten.no", "wsj.com", "smh.com.au", "theage.com.au", "newyorker.com",
        "wired.com", "thetimes.co.uk", "latimes.com", "theglobeandmail.com",
        "bloomberg.com", "afr.com",
    ]

    func testCoveredSitesHaveSnippets() {
        for host in covered {
            XCTAssertNotNil(SiteCleanupScripts.script(for: url("https://www.\(host)/article")), host)
        }
        XCTAssertGreaterThanOrEqual(SiteCleanupScripts.count, 25)   // incl. group members
    }

    func testUnknownHostHasNoSnippet() {
        XCTAssertNil(SiteCleanupScripts.script(for: url("https://example.com/x")))
        XCTAssertNil(SiteCleanupScripts.script(for: url("https://news.ycombinator.com/x")))
    }

    func testGroupMembersShareSnippet() {
        // Condé Nast + Nine/Fairfax members resolve to the shared snippet.
        XCTAssertEqual(SiteCleanupScripts.script(for: url("https://www.vanityfair.com/x")),
                       SiteCleanupScripts.script(for: url("https://www.newyorker.com/x")))
        XCTAssertEqual(SiteCleanupScripts.script(for: url("https://www.brisbanetimes.com.au/x")),
                       SiteCleanupScripts.script(for: url("https://www.smh.com.au/x")))
    }

    func testSnippetsAreSelfContainedIIFEs() {
        let forbidden = ["chrome.", "browser.", "ext_api", "runtime.sendMessage",
                         "getArchive", "getExtSrc", "sendNativeMessage"]
        for host in covered {
            let js = SiteCleanupScripts.script(for: url("https://www.\(host)/x"))!
            XCTAssertTrue(js.hasPrefix("(function()"), host)
            XCTAssertTrue(js.contains("try"), host)
            XCTAssertTrue(js.hasSuffix("})();"), host)
            for token in forbidden {
                XCTAssertFalse(js.contains(token), "\(host) uses forbidden \(token)")
            }
        }
    }
}

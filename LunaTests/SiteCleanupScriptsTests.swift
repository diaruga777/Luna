//
//  SiteCleanupScriptsTests.swift
//  LunaTests
//

import LunaArchiveReader
import XCTest

/// The bespoke per-site cleanup snippets (bundled JSON) load, match by
/// host/subdomain across the English + European news markets, and are self-contained
/// (no extension/cross-origin APIs that can't run in a plain WKWebView content world).
final class SiteCleanupScriptsTests: XCTestCase {
    private func url(_ s: String) -> URL { URL(string: s)! }

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

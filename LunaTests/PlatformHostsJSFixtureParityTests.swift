//
//  PlatformHostsJSFixtureParityTests.swift
//  LunaTests
//

import LunaURLClassification
import XCTest

/// The end-to-end smoke for `platform_hosts.generated.js`: the generated table
/// really loads in WebKit, `content.js`'s `recognizedPlatformPage` really runs on
/// top of it (injected in the same order as `background.js`'s
/// `injectContentScript`), and its verdict agrees with `PlatformRecognizer`.
///
/// The DATA is pinned elsewhere and far more cheaply: `PlatformHostsJSParityTests`
/// byte-compares the generated file against `PlatformRecognizer.rules`, and the
/// Swift detector's own tests cover the per-URL semantics. So this keeps a handful
/// of URLs — one positive with a host-suffix match, the two path-shape branches
/// that actually diverged historically (Bluesky's post-only requirement, Reddit's
/// app-native share link), and a non-platform control — rather than sweeping the
/// whole matrix through a browser at ~1000x the cost of the Swift test.
@MainActor
final class PlatformHostsJSFixtureParityTests: XCTestCase {

    private lazy var js = SafariJSTestHarness(self)

    /// Loads `platform_hosts.generated.js` THEN `content.js` at `urlString`
    /// (mirroring background.js's real injection order), then evaluates
    /// `window.__lunaRecognizedPlatformPage()` (nil for the JS `null`).
    private func recognizedPlatform(at urlString: String) -> String? {
        js.load(
            html: "<html><body></body></html>", urlString: urlString,
            scripts: [SafariJSTestHarness.platformHosts, SafariJSTestHarness.contentScript])
        return js.string("window.__lunaRecognizedPlatformPage()")
    }

    private func assertParity(_ urlString: String, file: StaticString = #filePath, line: UInt = #line) {
        let expected = PlatformRecognizer.recognize(urlString)?.platform.rawValue
        XCTAssertEqual(
            recognizedPlatform(at: urlString), expected,
            "content.js/PlatformRecognizer disagree on \(urlString)", file: file, line: line)
    }

    func testGeneratedTableClassifiesInWebKitTheWaySwiftDoes() {
        // A subdomain outside XLink's old fixed host set: both sides suffix-match
        // ANY x.com/twitter.com subdomain, and the path shape says "post".
        assertParity("https://some-other.twitter.com/user/status/123")
        // A bare Bluesky profile (no /post/) must NOT recognize — content.js used
        // to false-positive on any "post" segment anywhere in the path.
        assertParity("https://bsky.app/profile/alice.bsky.social")
        // Reddit's app-native share link — content.js used to miss this entirely
        // (no share-token branch), falling through to the article/product heuristics.
        assertParity("https://www.reddit.com/r/WhatsWrongWithYourDog/s/qRjWPbZ2bo")
        // A page on no platform at all.
        assertParity("https://en.wikipedia.org/wiki/Swift")
    }
}

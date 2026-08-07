//
//  LunaDeepLinkTests.swift
//  LunaTests
//

import LunaURLClassification
import XCTest
@testable import Luna

final class LunaDeepLinkTests: XCTestCase {

    // MARK: - Building a read link

    /// `readLink` builds a `<scheme>://read?url=…` link that round-trips the exact
    /// article URL back out through `articleURL(from:)`.
    func testReadLinkRoundTrips() {
        let cases: [(name: String, articleURL: String, scheme: String?, expectedScheme: String)] = [
            ("default scheme", "https://example.com/story", nil, "lunareader"),
            ("requested scheme", "https://example.com/story",
             LunaDeepLink.priceTrackerScheme, "lunapricetracker"),
            ("query and fragment", "https://example.com/p?id=42&ref=abc#section", nil, "lunareader"),
            ("characters needing encoding", "https://example.com/search?q=hello world&tag=a+b",
             nil, "lunareader"),
        ]

        for testCase in cases {
            let link = testCase.scheme.map {
                LunaDeepLink.readLink(forArticleURL: testCase.articleURL, scheme: $0)
            } ?? LunaDeepLink.readLink(forArticleURL: testCase.articleURL)
            guard let link else {
                XCTFail("\(testCase.name): readLink returned nil")
                continue
            }
            XCTAssertEqual(link.scheme, testCase.expectedScheme, testCase.name)
            XCTAssertEqual(link.host, "read", testCase.name)
            XCTAssertEqual(LunaDeepLink.articleURL(from: link), testCase.articleURL, testCase.name)
        }
    }

    // MARK: - Parsing an inbound link

    func testArticleURLParsing() {
        // Each app registers only its own scheme, but parsing accepts any of them —
        // the OS delivers only what the running app registered.
        var cases: [(name: String, url: String, expected: String?)] =
            LunaDeepLink.allSchemes.map {
                ("\($0) read link", "\($0)://read?url=https://example.com", "https://example.com")
            }
        cases += [
            ("wrong scheme", "https://read?url=https://example.com", nil),
            ("wrong host", "lunareader://open?url=https://example.com", nil),
            ("missing url parameter", "lunareader://read?other=value", nil),
            // The Safari-extension takeover overlay's "Back to Luna" link is a bare
            // `<scheme>://` with no host/path (see LunaSafari/Resources/background.js) —
            // it must be tolerated as "nothing to route", never crash or ingest junk.
            ("bare scheme with no host", "lunareader://", nil),
        ]

        for testCase in cases {
            guard let url = URL(string: testCase.url) else {
                XCTFail("\(testCase.name): unparseable test URL")
                continue
            }
            XCTAssertEqual(LunaDeepLink.articleURL(from: url), testCase.expected, testCase.name)
        }
    }

    func testOwnSchemeIsTheCentralLunaSchemeInTheTestHost() {
        // The unit-test host is the central Luna app, which registers luna://
        // (LUNA_URL_SCHEME). ownScheme reads the host bundle's CFBundleURLTypes, so
        // this is the one test that actually pins the Info.plist mirror.
        XCTAssertEqual(LunaDeepLink.ownScheme, "luna")
    }

    // MARK: - Rescue

    func testRescueLinkConstruction() {
        // `nil` = the default, which targets the host bundle's own scheme (luna://
        // in the test host).
        var cases: [(scheme: String?, expected: String)] =
            LunaDeepLink.allSchemes.map { ($0, "\($0)://rescue") }
        cases.append((nil, "luna://rescue"))

        for testCase in cases {
            let link = testCase.scheme.map { LunaDeepLink.rescueLink(scheme: $0) }
                ?? LunaDeepLink.rescueLink()
            XCTAssertEqual(
                link?.absoluteString, testCase.expected,
                "rescueLink(scheme: \(testCase.scheme ?? "own"))")
        }
    }

    // MARK: - Bounce-back flag (Feature 2)

    func testRequestsReturnToSourceReadsTheRetQueryItem() {
        let flagged = URL(string: "lunadownloader://read?url=https://example.com&ret=safari")!
        let unflagged = URL(string: "lunapricetracker://read?url=https://example.com")!
        XCTAssertTrue(LunaDeepLink.requestsReturnToSource(flagged))
        XCTAssertFalse(LunaDeepLink.requestsReturnToSource(unflagged))
    }

    func testRequestsReturnToSourceIgnoresAnyOtherRetValue() {
        let url = URL(string: "lunadownloader://read?url=https://example.com&ret=something-else")!
        XCTAssertFalse(LunaDeepLink.requestsReturnToSource(url))
    }

    func testRequestsReturnToSourceIsFalseForANonReadHost() {
        let url = URL(string: "luna://media?url=https://example.com&ret=safari")!
        XCTAssertFalse(LunaDeepLink.requestsReturnToSource(url))
    }

    /// The extra `ret` query item must not affect `articleURL(from:)` at all —
    /// extra query params parse harmlessly, exactly like every other one.
    func testArticleURLIsUnaffectedByTheRetFlag() {
        let url = URL(string: "lunareader://read?url=https://example.com/story&ret=safari")!
        XCTAssertEqual(LunaDeepLink.articleURL(from: url), "https://example.com/story")
        XCTAssertTrue(LunaDeepLink.requestsReturnToSource(url))
    }

    // MARK: - Media view link (Feature 2's Live Activity tap-to-view)

    func testMediaViewLinkRoundTrips() {
        let link = LunaDeepLink.mediaViewLink(
            scheme: LunaDeepLink.downloaderScheme, sourceURLString: "https://example.com/video")
        XCTAssertEqual(link?.absoluteString, "lunadownloader://media?url=https://example.com/video")
        XCTAssertEqual(link.flatMap(LunaDeepLink.mediaViewURLString(from:)), "https://example.com/video")
    }

    func testMediaViewURLStringIsNilForAReadLink() {
        let url = URL(string: "lunadownloader://read?url=https://example.com/video")!
        XCTAssertNil(LunaDeepLink.mediaViewURLString(from: url))
    }

    func testIsRescueLink() {
        var cases: [(url: String, isRescue: Bool)] =
            LunaDeepLink.allSchemes.map { ("\($0)://rescue", true) }
        cases += [
            ("lunareader://read", false),
            ("https://example.com/rescue", false),
        ]

        for testCase in cases {
            guard let url = URL(string: testCase.url) else {
                XCTFail("unparseable test URL \(testCase.url)")
                continue
            }
            XCTAssertEqual(LunaDeepLink.isRescueLink(url), testCase.isRescue, testCase.url)
        }
    }
}

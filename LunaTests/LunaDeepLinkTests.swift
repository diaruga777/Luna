//
//  LunaDeepLinkTests.swift
//  LunaTests
//

import LunaURLClassification
import XCTest
@testable import Luna

final class LunaDeepLinkTests: XCTestCase {

    // MARK: - Parsing a read link built exactly like content.js builds it

    /// `content.js` is the only place a `<scheme>://read?url=…` link is BUILT
    /// (`scheme + "://read?url=" + encodeURIComponent(sourceURL)`, content.js:2373)
    /// — Swift only parses it back out via `articleURL(from:)`. This pins that
    /// parse against literal URL strings shaped exactly like the JS output,
    /// rather than round-tripping through a Swift builder nothing in production
    /// ever calls.
    func testReadLinkRoundTrips() {
        let cases: [(name: String, articleURL: String, scheme: String, expectedScheme: String)] = [
            ("default scheme", "https://example.com/story", "lunareader", "lunareader"),
            ("requested scheme", "https://example.com/story",
             LunaDeepLink.priceTrackerScheme, "lunapricetracker"),
            ("query and fragment", "https://example.com/p?id=42&ref=abc#section",
             "lunareader", "lunareader"),
            ("characters needing encoding", "https://example.com/search?q=hello world&tag=a+b",
             "lunareader", "lunareader"),
        ]

        // The characters `encodeURIComponent` leaves unescaped (RFC 3986 unreserved).
        let encodeURIComponentUnreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

        for testCase in cases {
            let encoded = testCase.articleURL.addingPercentEncoding(
                withAllowedCharacters: encodeURIComponentUnreserved) ?? testCase.articleURL
            guard let link = URL(string: "\(testCase.scheme)://read?url=\(encoded)") else {
                XCTFail("\(testCase.name): failed to build the literal test URL")
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

    // MARK: - Media SHARE link (the finished activity's Share button)

    /// The share link is the view link plus a flag: both the wrapped source URL
    /// and the share request come back out of it, so the deck still centers on
    /// the item while the app also raises the share sheet.
    func testMediaShareLinkRoundTrips() throws {
        let link = try XCTUnwrap(LunaDeepLink.mediaShareLink(
            scheme: LunaDeepLink.downloaderScheme,
            sourceURLString: "https://example.com/clip?id=7&t=3"))
        XCTAssertEqual(link.host, "media")
        XCTAssertEqual(
            LunaDeepLink.mediaViewURLString(from: link), "https://example.com/clip?id=7&t=3")
        XCTAssertTrue(LunaDeepLink.mediaShareRequested(from: link))
    }

    func testMediaShareRequestedDistinguishesShareFromPlainView() throws {
        let viewLink = try XCTUnwrap(LunaDeepLink.mediaViewLink(
            scheme: LunaDeepLink.downloaderScheme, sourceURLString: "https://example.com/video"))
        XCTAssertFalse(LunaDeepLink.mediaShareRequested(from: viewLink))
    }

    func testMediaShareRequestedToleratesExtraAndReorderedQueryItems() {
        let cases: [(url: String, isShare: Bool)] = [
            ("lunadownloader://media?share=1&url=https://example.com/video", true),
            ("luna://media?url=https://example.com/video&ret=safari&share=1", true),
            // Only the flag's own value counts — a stray `share` means nothing else.
            ("luna://media?url=https://example.com/video&share=0", false),
            ("luna://media?url=https://example.com/video&share=yes", false),
            // Foreign schemes and other hosts never carry the share route.
            ("https://example.com/media?url=x&share=1", false),
            ("lunadownloader://read?url=https://example.com&share=1", false),
        ]
        for testCase in cases {
            guard let url = URL(string: testCase.url) else {
                XCTFail("unparseable test URL \(testCase.url)")
                continue
            }
            XCTAssertEqual(
                LunaDeepLink.mediaShareRequested(from: url), testCase.isShare, testCase.url)
        }
    }

    /// The share link still resolves its source URL when other params sit
    /// between the two — the whole point of reading bare query items.
    func testMediaViewURLStringSurvivesTheShareFlag() {
        let url = URL(string: "luna://media?share=1&url=https://example.com/a%20b")!
        XCTAssertEqual(LunaDeepLink.mediaViewURLString(from: url), "https://example.com/a b")
    }

    func testPriceTrackerAddSellerLinkRoundTripsTheItemID() throws {
        let id = UUID(uuidString: "78A9292B-5E2C-4CF4-8F5B-B9BE7C13C90E")!
        let link = try XCTUnwrap(LunaDeepLink.priceTrackerAddSellerLink(
            scheme: LunaDeepLink.priceTrackerScheme, itemID: id))
        XCTAssertEqual(link.host, "price-add-seller")
        XCTAssertEqual(LunaDeepLink.priceTrackerAddSellerItemID(from: link), id)
        XCTAssertNil(LunaDeepLink.priceTrackerAddSellerItemID(
            from: URL(string: "lunapricetracker://price-add-seller?item=not-a-uuid")!))
    }

    func testExtensionBundleIdentifiersResolveTheirContainingAppScheme() {
        let expected = [
            "com.example.luna.share": LunaDeepLink.lunaScheme,
            "com.example.luna.reader.action2": LunaDeepLink.readerScheme,
            "com.example.luna.downloader.safari": LunaDeepLink.downloaderScheme,
            "com.example.luna.pricetracker.share": LunaDeepLink.priceTrackerScheme,
        ]
        for (bundleIdentifier, scheme) in expected {
            XCTAssertEqual(
                LunaDeepLink.appScheme(forBundleIdentifier: bundleIdentifier), scheme,
                bundleIdentifier)
        }
    }

    // MARK: - Resolved-media link (Safari's in-page player download)

    func testIsResolvedMediaLink() {
        var cases: [(url: String, isResolvedMedia: Bool)] =
            LunaDeepLink.allSchemes.map { ("\($0)://resolvedmedia", true) }
        cases += [
            ("lunadownloader://resolvedmedia?ret=safari", true),
            ("lunadownloader://rescue", false),
            ("lunadownloader://read?url=https://example.com", false),
            ("https://example.com/resolvedmedia", false),
        ]

        for testCase in cases {
            guard let url = URL(string: testCase.url) else {
                XCTFail("unparseable test URL \(testCase.url)")
                continue
            }
            XCTAssertEqual(
                LunaDeepLink.isResolvedMediaLink(url), testCase.isResolvedMedia, testCase.url)
        }
    }

    /// The drain link may bounce back to Safari, exactly as a media pill save
    /// does — and only when it carries the flag.
    func testResolvedMediaLinkHonorsTheReturnFlag() {
        XCTAssertTrue(LunaDeepLink.requestsReturnToSource(
            URL(string: "lunadownloader://resolvedmedia?ret=safari")!))
        XCTAssertFalse(LunaDeepLink.requestsReturnToSource(
            URL(string: "lunadownloader://resolvedmedia")!))
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

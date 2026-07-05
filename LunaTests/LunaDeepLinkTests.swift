//
//  LunaDeepLinkTests.swift
//  LunaTests
//

import LunaURLClassification
import XCTest
@testable import Luna

final class LunaDeepLinkTests: XCTestCase {

    func testReadLinkWrapsArticleURL() {
        let link = LunaDeepLink.readLink(forArticleURL: "https://example.com/story")
        XCTAssertEqual(link?.scheme, "lunareader")
        XCTAssertEqual(link?.host, "read")
        XCTAssertEqual(
            LunaDeepLink.articleURL(from: link!),
            "https://example.com/story")
    }

    func testReadLinkTargetsRequestedScheme() {
        let link = LunaDeepLink.readLink(
            forArticleURL: "https://example.com/story",
            scheme: LunaDeepLink.priceTrackerScheme)
        XCTAssertEqual(link?.scheme, "lunapricetracker")
        XCTAssertEqual(LunaDeepLink.articleURL(from: link!), "https://example.com/story")
    }

    func testRoundTripsURLWithQueryAndFragment() {
        let original = "https://example.com/p?id=42&ref=abc#section"
        let link = LunaDeepLink.readLink(forArticleURL: original)
        XCTAssertNotNil(link)
        XCTAssertEqual(LunaDeepLink.articleURL(from: link!), original)
    }

    func testRoundTripsURLWithEncodedCharacters() {
        let original = "https://example.com/search?q=hello world&tag=a+b"
        let link = LunaDeepLink.readLink(forArticleURL: original)
        XCTAssertNotNil(link)
        XCTAssertEqual(LunaDeepLink.articleURL(from: link!), original)
    }

    func testArticleURLAcceptsEveryLunaScheme() {
        // Each app registers only its own scheme, but parsing accepts any of
        // them — the OS delivers only what the running app registered.
        for scheme in LunaDeepLink.allSchemes {
            let url = URL(string: "\(scheme)://read?url=https://example.com")!
            XCTAssertEqual(LunaDeepLink.articleURL(from: url), "https://example.com")
        }
    }

    func testArticleURLRejectsWrongScheme() {
        let url = URL(string: "https://read?url=https://example.com")!
        XCTAssertNil(LunaDeepLink.articleURL(from: url))
    }

    func testArticleURLRejectsWrongHost() {
        let url = URL(string: "lunareader://open?url=https://example.com")!
        XCTAssertNil(LunaDeepLink.articleURL(from: url))
    }

    func testArticleURLReturnsNilWhenURLParamMissing() {
        let url = URL(string: "lunareader://read?other=value")!
        XCTAssertNil(LunaDeepLink.articleURL(from: url))
    }

    func testSchemeConstantsAreStable() {
        // The schemes are registered in Info.plist ($(LUNA_URL_SCHEME), set per
        // app target) and mirrored in the Safari extension's content script;
        // drift would break inbound links.
        XCTAssertEqual(LunaDeepLink.readerScheme, "lunareader")
        XCTAssertEqual(LunaDeepLink.downloaderScheme, "lunadownloader")
        XCTAssertEqual(LunaDeepLink.priceTrackerScheme, "lunapricetracker")
        XCTAssertEqual(
            LunaDeepLink.allSchemes,
            [LunaDeepLink.readerScheme, LunaDeepLink.downloaderScheme,
             LunaDeepLink.priceTrackerScheme])
    }

    func testOwnSchemeFallsBackToReaderWithoutURLTypes() {
        // The unit-test host is the Reader app, whose registered scheme IS the
        // reader scheme — and bundles without CFBundleURLTypes (extensions)
        // fall back to it too.
        XCTAssertEqual(LunaDeepLink.ownScheme, "lunareader")
    }
}

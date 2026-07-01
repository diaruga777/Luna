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

    func testSchemeConstantIsStable() {
        // The scheme is registered in Info.plist; drift would break inbound links.
        XCTAssertEqual(LunaDeepLink.scheme, "lunareader")
    }
}

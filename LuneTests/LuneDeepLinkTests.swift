//
//  LuneDeepLinkTests.swift
//  LuneTests
//

import LuneURLClassification
import XCTest
@testable import Lune

final class LuneDeepLinkTests: XCTestCase {

    func testReadLinkWrapsArticleURL() {
        let link = LuneDeepLink.readLink(forArticleURL: "https://example.com/story")
        XCTAssertEqual(link?.scheme, "lunereader")
        XCTAssertEqual(link?.host, "read")
        XCTAssertEqual(
            LuneDeepLink.articleURL(from: link!),
            "https://example.com/story")
    }

    func testRoundTripsURLWithQueryAndFragment() {
        let original = "https://example.com/p?id=42&ref=abc#section"
        let link = LuneDeepLink.readLink(forArticleURL: original)
        XCTAssertNotNil(link)
        XCTAssertEqual(LuneDeepLink.articleURL(from: link!), original)
    }

    func testRoundTripsURLWithEncodedCharacters() {
        let original = "https://example.com/search?q=hello world&tag=a+b"
        let link = LuneDeepLink.readLink(forArticleURL: original)
        XCTAssertNotNil(link)
        XCTAssertEqual(LuneDeepLink.articleURL(from: link!), original)
    }

    func testArticleURLRejectsWrongScheme() {
        let url = URL(string: "https://read?url=https://example.com")!
        XCTAssertNil(LuneDeepLink.articleURL(from: url))
    }

    func testArticleURLRejectsWrongHost() {
        let url = URL(string: "lunereader://open?url=https://example.com")!
        XCTAssertNil(LuneDeepLink.articleURL(from: url))
    }

    func testArticleURLReturnsNilWhenURLParamMissing() {
        let url = URL(string: "lunereader://read?other=value")!
        XCTAssertNil(LuneDeepLink.articleURL(from: url))
    }

    func testSchemeConstantIsStable() {
        // The scheme is registered in Info.plist; drift would break inbound links.
        XCTAssertEqual(LuneDeepLink.scheme, "lunereader")
    }
}

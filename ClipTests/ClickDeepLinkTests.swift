//
//  ClickDeepLinkTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

final class ClickDeepLinkTests: XCTestCase {

    func testReadLinkWrapsArticleURL() {
        let link = ClickDeepLink.readLink(forArticleURL: "https://example.com/story")
        XCTAssertEqual(link?.scheme, "clickreader")
        XCTAssertEqual(link?.host, "read")
        XCTAssertEqual(
            ClickDeepLink.articleURL(from: link!),
            "https://example.com/story")
    }

    func testRoundTripsURLWithQueryAndFragment() {
        let original = "https://example.com/p?id=42&ref=abc#section"
        let link = ClickDeepLink.readLink(forArticleURL: original)
        XCTAssertNotNil(link)
        XCTAssertEqual(ClickDeepLink.articleURL(from: link!), original)
    }

    func testRoundTripsURLWithEncodedCharacters() {
        let original = "https://example.com/search?q=hello world&tag=a+b"
        let link = ClickDeepLink.readLink(forArticleURL: original)
        XCTAssertNotNil(link)
        XCTAssertEqual(ClickDeepLink.articleURL(from: link!), original)
    }

    func testArticleURLRejectsWrongScheme() {
        let url = URL(string: "https://read?url=https://example.com")!
        XCTAssertNil(ClickDeepLink.articleURL(from: url))
    }

    func testArticleURLRejectsWrongHost() {
        let url = URL(string: "clickreader://open?url=https://example.com")!
        XCTAssertNil(ClickDeepLink.articleURL(from: url))
    }

    func testArticleURLReturnsNilWhenURLParamMissing() {
        let url = URL(string: "clickreader://read?other=value")!
        XCTAssertNil(ClickDeepLink.articleURL(from: url))
    }

    func testSchemeConstantIsStable() {
        // The scheme is registered in Info.plist; drift would break inbound links.
        XCTAssertEqual(ClickDeepLink.scheme, "clickreader")
    }
}

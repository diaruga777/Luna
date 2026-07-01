//
//  SocialPostFinderTests.swift
//  LunaTests
//

import LunaPlatforms
import XCTest
@testable import Luna

final class SocialPostFinderTests: XCTestCase {

    func testDecodesDuckDuckGoResultURLs() {
        let html = """
        <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fx.com%2Fjack%2Fstatus%2F20&rut=x">tweet</a>
        <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa">other</a>
        """
        let urls = SocialPostFinder.resultURLs(inHTML: html)
        XCTAssertEqual(urls.first?.absoluteString, "https://x.com/jack/status/20")
        XCTAssertEqual(urls.count, 2)
    }

    func testNoResultsYieldsEmpty() {
        XCTAssertTrue(SocialPostFinder.resultURLs(inHTML: "<html>nothing</html>").isEmpty)
    }

    func testBestMatchPrefersPostByHandle() {
        let urls = [
            URL(string: "https://x.com/explore")!,                 // not a post
            URL(string: "https://x.com/someoneelse/status/1")!,    // post, wrong handle
            URL(string: "https://x.com/jack/status/20")!,          // post by handle
        ]
        XCTAssertEqual(
            SocialPostFinder.bestMatch(in: urls, platform: .x, handle: "jack")?.absoluteString,
            "https://x.com/jack/status/20")
    }

    func testBestMatchFallsBackToAnyPost() {
        let urls = [URL(string: "https://x.com/someoneelse/status/1")!]
        XCTAssertEqual(
            SocialPostFinder.bestMatch(in: urls, platform: .x, handle: "jack")?.absoluteString,
            "https://x.com/someoneelse/status/1")
    }

    func testBestMatchRejectsNonPosts() {
        let urls = [URL(string: "https://x.com/jack")!, URL(string: "https://example.com/x")!]
        XCTAssertNil(SocialPostFinder.bestMatch(in: urls, platform: .x, handle: "jack"))
    }
}

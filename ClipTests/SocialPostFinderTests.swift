//
//  SocialPostFinderTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

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
}

//
//  SafariPageSaveTests.swift
//  LunaTests
//

import XCTest
@testable import LunaIntents

final class SafariPageSaveTests: XCTestCase {

    // MARK: - Query construction

    func testQuotesTitleAndAppendsSite() {
        XCTAssertEqual(
            SafariPageSave.searchQuery(title: "The math of slime", site: "Veritasium"),
            "\"The math of slime\" Veritasium")
    }

    func testNilSiteOmitsSecondTerm() {
        XCTAssertEqual(
            SafariPageSave.searchQuery(title: "Some Article Title", site: nil),
            "\"Some Article Title\"")
    }

    func testEmptySiteIsTreatedAsNil() {
        XCTAssertEqual(
            SafariPageSave.searchQuery(title: "Some Article Title", site: "   "),
            "\"Some Article Title\"")
    }

    func testEmptyTitleYieldsEmptyQuery() {
        XCTAssertEqual(SafariPageSave.searchQuery(title: "  ", site: "Site"), "")
    }

    func testTrimsWhitespaceAroundTitleAndSite() {
        XCTAssertEqual(
            SafariPageSave.searchQuery(title: "  Title  ", site: "  Site  "),
            "\"Title\" Site")
    }

    // MARK: - Result filtering

    func testDropsSearchEngineAndVideoHosts() {
        let urls = [
            URL(string: "https://duckduckgo.com/l/?uddg=x")!,
            URL(string: "https://www.bing.com/search?q=x")!,
            URL(string: "https://www.youtube.com/watch?v=abc")!,
            URL(string: "https://youtu.be/abc")!,
            URL(string: "https://www.google.co.uk/search?q=x")!,
            URL(string: "https://example.com/articles/the-math-of-slime")!,
        ]
        XCTAssertEqual(
            SafariPageSave.filterArticleCandidates(urls).map(\.absoluteString),
            ["https://example.com/articles/the-math-of-slime"])
    }

    func testKeepsFirstArticleLikeResultOrder() {
        let urls = [
            URL(string: "https://news.example.com/a")!,
            URL(string: "https://blog.example.org/b")!,
        ]
        XCTAssertEqual(SafariPageSave.filterArticleCandidates(urls), urls)
    }

    func testURLWithNoHostIsDropped() {
        let urls = [URL(string: "not-a-url-with-host")!]
        XCTAssertTrue(SafariPageSave.filterArticleCandidates(urls).isEmpty)
    }
}

//
//  ReadingListSearchEngineTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

final class ReadingListSearchEngineTests: XCTestCase {

    private func entry(title: String, body: String) -> (SearchEntry, UUID) {
        let item = ReadingListItem(urlString: "https://example.com/\(UUID().uuidString)")
        return (SearchEntry(item: item, titleText: title.lowercased(), bodyText: body.lowercased()), item.id)
    }

    func testTitleHitsRankBeforeBodyHits() {
        let (bodyOnly, bodyID) = entry(title: "unrelated headline", body: "the swift language is great")
        let (titleHit, titleID) = entry(title: "swift tutorial", body: "irrelevant")
        let (noHit, _) = entry(title: "nothing here", body: "nothing here")
        let ranked = ReadingListSearchEngine.rank(needle: "swift", in: [bodyOnly, titleHit, noHit])
        XCTAssertEqual(ranked.map(\.id), [titleID, bodyID])
    }

    func testMatchesMidWordSubstrings() {
        let (e, id) = entry(title: "The Quick Brown Fox", body: "")
        // `rank` takes an already-normalized (lowercased) needle; entry text is
        // lowercased at build time. Public `stringMatches` does the lowercasing.
        let ranked = ReadingListSearchEngine.rank(needle: "quick", in: [e])
        XCTAssertEqual(ranked.map(\.id), [id])
    }

    func testNoMatchReturnsEmpty() {
        let (e, _) = entry(title: "apples", body: "oranges")
        XCTAssertTrue(ReadingListSearchEngine.rank(needle: "bananas", in: [e]).isEmpty)
    }

    func testBodyOnlyMatchIncluded() {
        let (e, id) = entry(title: "headline", body: "deep in the article we mention kubernetes")
        XCTAssertEqual(ReadingListSearchEngine.rank(needle: "kubernetes", in: [e]).map(\.id), [id])
    }
}

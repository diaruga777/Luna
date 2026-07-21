//
//  ArticleCardOrderingTests.swift
//  LunaTests
//

import LunaModels
import XCTest
@testable import Luna

final class ArticleCardOrderingTests: XCTestCase {

    func testReadArticlesStayVisibleAfterActiveArticles() {
        let oldActive = article("old-active", daysAgo: 4, readState: .opened)
        let newestRead = article("newest-read", daysAgo: 0, readState: .read)
        let newestActive = article("newest-active", daysAgo: 1, readState: .unopened)
        let oldRead = article("old-read", daysAgo: 7, readState: .read)

        let ordered = ArticleCardsViewController.orderedReaderItems(
            [oldRead, newestRead, oldActive, newestActive])

        XCTAssertEqual(ordered.map(\.id), [newestActive.id, oldActive.id, newestRead.id, oldRead.id])
    }

    func testArchivedArticlesAreNotCarouselCards() {
        let active = article("active", daysAgo: 1, readState: .opened)
        var archived = article("archived", daysAgo: 0, readState: .unopened)
        archived.archivedAt = Date()

        XCTAssertEqual(
            ArticleCardsViewController.orderedReaderItems([archived, active]).map(\.id),
            [active.id])
    }

    private func article(
        _ seed: String, daysAgo: TimeInterval, readState: ReadingListItem.ReadState
    ) -> ReadingListItem {
        ReadingListItem(
            seed: seed,
            urlString: "https://example.com/\(seed)",
            title: seed,
            dateAdded: Date(timeIntervalSince1970: 1_000_000 - daysAgo * 86_400),
            state: .ready,
            readState: readState)
    }
}

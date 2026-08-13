//
//  ArticleEntityDisplayTests.swift
//  LunaTests
//

import LunaModels
import XCTest
@testable import Luna

/// `ArticleEntity`'s field mapping from `SavedItem` and its visible
/// "title / source host · date" representation. `subtitleText` is exercised
/// directly (not through `DisplayRepresentation`/`LocalizedStringResource`,
/// which aren't meaningfully comparable in a unit test).
final class ArticleEntityDisplayTests: XCTestCase {

    private let savedDate = Date(timeIntervalSince1970: 1_750_000_000)

    func testMapsTitleDateAndSourceHostFromItem() {
        let item = SavedItem(
            seed: "a", urlString: "https://www.theatlantic.com/politics/a", title: "A Boston Story",
            dateAdded: savedDate)
        let entity = ArticleEntity(item: item)
        XCTAssertEqual(entity.id, item.id)
        XCTAssertEqual(entity.title, "A Boston Story")
        XCTAssertEqual(entity.savedDate, savedDate)
        XCTAssertEqual(entity.sourceHost, "theatlantic.com")
    }

    func testFallsBackToURLWhenTitleMissing() {
        let item = SavedItem(
            seed: "b", urlString: "https://example.com/b", title: nil, dateAdded: savedDate)
        XCTAssertEqual(ArticleEntity(item: item).title, "https://example.com/b")
    }

    func testUsesBumpDateOverDateAddedWhenPresent() {
        let bumped = savedDate.addingTimeInterval(1000)
        var item = SavedItem(
            seed: "c", urlString: "https://example.com/c", title: "C", dateAdded: savedDate)
        item.bumpDate = bumped
        XCTAssertEqual(ArticleEntity(item: item).savedDate, bumped)
    }

    func testSourceHostEmptyForSyntheticURL() {
        let item = SavedItem(
            seed: "d", urlString: "lunadoc://abc", title: "A Document", dateAdded: savedDate)
        XCTAssertEqual(ArticleEntity(item: item).sourceHost, "")
    }

    // MARK: - subtitleText

    func testSubtitleCombinesHostAndDate() {
        let subtitle = ArticleEntity.subtitleText(sourceHost: "theatlantic.com", savedDate: savedDate)
        XCTAssertTrue(subtitle.hasPrefix("theatlantic.com · "))
    }

    func testSubtitleIsDateOnlyWhenNoHost() {
        let subtitle = ArticleEntity.subtitleText(sourceHost: "", savedDate: savedDate)
        XCTAssertFalse(subtitle.contains("·"))
        XCTAssertFalse(subtitle.isEmpty)
    }
}

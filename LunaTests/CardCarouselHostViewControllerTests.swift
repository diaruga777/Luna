//
//  CardCarouselHostViewControllerTests.swift
//  LunaTests
//
//  CardCarouselHostViewController is the shared skeleton behind Reader's and
//  Downloader's root screens (Wave 3C). Its permanent-util-card index math
//  (`itemIndex(forCarouselIndex:itemCount:)`) is the one piece of that base
//  class cheaply testable in isolation — no view loading, no carousel, no
//  store.
//

import UIKit
import XCTest
@testable import Luna

final class CardCarouselHostViewControllerTests: XCTestCase {

    func testRecentArticleArtworkSettlesAsHeaderInsteadOfCardSizedThumbnail() {
        let card = CGRect(x: 20, y: 80, width: 350, height: 620)
        let geometry = UtilCardSaveTransitionGeometry.fallback(
            in: card, kind: .article, sourceTitleHeight: 42)

        XCTAssertEqual(geometry.thumbnail.size, CGSize(width: 30, height: 30))
        XCTAssertEqual(geometry.thumbnail.minX, card.minX + 20)
        XCTAssertLessThan(geometry.thumbnail.height, card.height * 0.1)
        XCTAssertEqual(geometry.title.minX, geometry.thumbnail.maxX + 12)
    }

    func testRecentProductArtworkSettlesIntoProductCardHeader() {
        let card = CGRect(x: 20, y: 80, width: 350, height: 620)
        let geometry = UtilCardSaveTransitionGeometry.fallback(
            in: card, kind: .product, sourceTitleHeight: 42)

        XCTAssertEqual(geometry.thumbnail.size, CGSize(width: 64, height: 64))
        XCTAssertEqual(geometry.thumbnail.origin, CGPoint(x: 38, y: 98))
        XCTAssertEqual(geometry.title.height, 64)
    }

    private final class TestHost: CardCarouselHostViewController {}

    // MARK: - Only a row with artwork grows into a card

    /// The paste row is 40pt tall and holds a live system paste control; grown
    /// into the card frame as one flat snapshot it filled the screen with a
    /// smeared copy of itself. A source that cannot hand over real artwork gets
    /// no handoff at all — it says what it is doing in place instead.
    @MainActor
    func testASourceWithoutRowArtworkStartsNoGrowTransition() {
        let host = TestHost()
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let pasteRow = OnboardingPasteRow()
        pasteRow.frame = CGRect(x: 20, y: 780, width: 350, height: 40)
        host.view.addSubview(pasteRow)

        host.beginUtilCardSaveTransition(
            for: "https://example.com/a", from: pasteRow)

        XCTAssertNil(
            host.pendingUtilCardSaveURLString,
            "A 40pt paste row must never be stretched into the card frame")
    }

    @MainActor
    func testAUtilURLRowStillGrowsIntoItsCard() {
        let host = TestHost()
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let row = UtilURLRow(style: .recent)
        row.configure(RecentURLPreview(
            urlString: "https://recent.example/a",
            title: "Recent a",
            subtitle: "recent.example",
            kind: .article,
            imageData: nil))
        row.frame = CGRect(x: 20, y: 200, width: 350, height: 74)
        host.view.addSubview(row)

        host.beginUtilCardSaveTransition(for: "https://recent.example/a", from: row)

        XCTAssertEqual(host.pendingUtilCardSaveURLString, "https://recent.example/a")
        host.cancelUtilCardSaveTransition()
    }

    @MainActor
    func testPagingTowardLastCardWaitsUntilCenterToRevealArchiveTab() {
        let host = TestHost()
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        var isRightmost = false
        host.mountArchiveTray(shifting: { [] }, canPull: { isRightmost })
        host.viewDidLayoutSubviews()

        XCTAssertFalse(host.archiveTray?.isPullAvailableForTesting ?? true)
        host.updateArchivePullAvailability(forTargetIndex: 2, cardCount: 3, animated: false)
        XCTAssertFalse(
            host.archiveTray?.isPullAvailableForTesting ?? true,
            "Selecting the incoming last card must not reveal the tab at animation start")

        isRightmost = true
        host.refreshArchivePullAvailability(animated: false)
        XCTAssertTrue(
            host.archiveTray?.isPullAvailableForTesting ?? false,
            "The did-center refresh reveals the tab at animation completion")
    }

    // MARK: - The permanent util card shifts every saved item by one

    func testUtilCardShiftsEverySavedItemIndexByOne() {
        let host = TestHost()
        XCTAssertEqual(host.cardOffset, 1)
        XCTAssertNil(host.itemIndex(forCarouselIndex: 0, itemCount: 3))
        XCTAssertEqual(host.itemIndex(forCarouselIndex: 1, itemCount: 3), 0)
        XCTAssertEqual(host.itemIndex(forCarouselIndex: 3, itemCount: 3), 2)
    }

    func testUtilCardIndexMathRejectsOutOfRangeIndexes() {
        let host = TestHost()
        XCTAssertNil(host.itemIndex(forCarouselIndex: 4, itemCount: 3))
        XCTAssertNil(host.itemIndex(forCarouselIndex: -1, itemCount: 3))
    }

    // MARK: - Empty item list

    func testEmptyItemListHasNoValidIndex() {
        let host = TestHost()
        XCTAssertNil(host.itemIndex(forCarouselIndex: 0, itemCount: 0))
        XCTAssertNil(host.itemIndex(forCarouselIndex: 1, itemCount: 0))
    }
}

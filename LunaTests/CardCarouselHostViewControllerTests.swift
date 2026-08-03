//
//  CardCarouselHostViewControllerTests.swift
//  LunaTests
//
//  CardCarouselHostViewController is the shared skeleton behind Reader's and
//  Downloader's root screens (Wave 3C). Its permanent-util-card index math
//  (`itemIndex(forCarouselIndex:itemCount:)`) is the one piece of that base
//  class cheaply testable in isolation — no view loading, no carousel, no
//  store. `SavedMediaCardsViewController`'s own storage-state/kind dispatch
//  (`storageStateKey`/`providerBacking`) is pure-shaped but `private` and only
//  reachable through a fully-constructed view controller that eagerly touches
//  the live `SavedMediaStore.shared` singleton in `init` — testing it would
//  need a store-injection seam this wave doesn't add, so it isn't covered here.
//

import LunaMediaDownload
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

    func testPasteboardCommitKeepsAlreadyRepresentedNewerPaste() {
        XCTAssertFalse(PasteboardCommitPolicy.shouldClearCommittedCard(
            committedChangeCount: 10,
            currentPasteboardChangeCount: 11,
            representedChangeCount: 11))
    }

    func testPasteboardCommitClearsItsOwnRepresentedCardBeforeRefreshing() {
        XCTAssertTrue(PasteboardCommitPolicy.shouldClearCommittedCard(
            committedChangeCount: 10,
            currentPasteboardChangeCount: 11,
            representedChangeCount: 10))
    }

    private final class TestHost: CardCarouselHostViewController {}

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

    // MARK: - Pasteboard privacy and temporary-media policy

    /// This legacy placeholder reads nothing until the system paste button says so: no
    /// control, no read path. (The prompt-timing heuristic that used to choose
    /// failure copy is gone with the prompt it detected.)
    func testPlaceholderCardWithoutAPasteHandlerStaysAPlainTappableCard() {
        let withControl = PasteboardPlaceholderCardContentViewController(
            title: "Paste Link", detail: "detail", onPaste: { _ in })
        let withoutControl = PasteboardPlaceholderCardContentViewController(
            title: "Loading Paste", detail: "detail")
        withControl.loadViewIfNeeded()
        withoutControl.loadViewIfNeeded()

        XCTAssertFalse(withControl.allowsCardTap(at: .zero))
        XCTAssertTrue(withoutControl.allowsCardTap(at: .zero))
        XCTAssertNotNil(withControl.pasteConfiguration)
        XCTAssertFalse(withControl.view.isAccessibilityElement)
        XCTAssertTrue(withoutControl.view.isAccessibilityElement)
        XCTAssertTrue(Self.containsPasteControl(withControl.view))
        XCTAssertFalse(Self.containsPasteControl(withoutControl.view))
    }

    private static func containsPasteControl(_ view: UIView) -> Bool {
        if view is UIPasteControl { return true }
        return view.subviews.contains(where: containsPasteControl)
    }

    func testTemporaryPasteboardMediaExpiresAfterOneHour() {
        XCTAssertEqual(PasteboardTemporaryMediaPolicy.lifetime, 3_600)
        let expiry = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(PasteboardTemporaryMediaPolicy.isExpired(
            expiresAt: expiry, now: expiry.addingTimeInterval(-0.001)))
        XCTAssertTrue(PasteboardTemporaryMediaPolicy.isExpired(
            expiresAt: expiry, now: expiry))
    }

    func testTemporaryVideoStartsPausedAndCommitsOnlyOnFirstPlay() {
        var commitCount = 0
        let media = DownloadedMedia(
            fileURL: URL(fileURLWithPath: "/tmp/temporary-pasteboard-video.mp4"),
            kind: .video)
        let content = TemporaryPasteboardMediaCardContentViewController(media: media) {
            commitCount += 1
        }

        content.cardDidBecomeCentered()
        XCTAssertTrue(content.isPlayable)
        XCTAssertFalse(content.isPlaying)
        XCTAssertEqual(commitCount, 0)

        content.setPlaying(true)
        XCTAssertTrue(content.isPlaying)
        XCTAssertEqual(commitCount, 1)

        content.setPlaying(false)
        content.setPlaying(true)
        XCTAssertEqual(commitCount, 1)
    }
}

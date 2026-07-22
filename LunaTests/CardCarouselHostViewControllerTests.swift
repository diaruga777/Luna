//
//  CardCarouselHostViewControllerTests.swift
//  LunaTests
//
//  CardCarouselHostViewController is the shared skeleton behind Reader's and
//  Downloader's root screens (Wave 3C). Its pasteboard-offset index math
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

    /// Flips `hasLeadingPasteboardCard` on demand, mirroring how a real
    /// subclass reflects its own pasteboard state.
    private final class TestHost: CardCarouselHostViewController {
        var pasteboardCardShowing = false
        override var hasLeadingPasteboardCard: Bool { pasteboardCardShowing }
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

    // MARK: - No leading pasteboard card: carousel index == item index

    func testNoPasteboardCardMapsCarouselIndexDirectlyToItemIndex() {
        let host = TestHost()
        XCTAssertEqual(host.cardOffset, 0)
        XCTAssertEqual(host.itemIndex(forCarouselIndex: 0, itemCount: 3), 0)
        XCTAssertEqual(host.itemIndex(forCarouselIndex: 2, itemCount: 3), 2)
    }

    func testNoPasteboardCardOutOfRangeIndexIsNil() {
        let host = TestHost()
        XCTAssertNil(host.itemIndex(forCarouselIndex: 3, itemCount: 3))
        XCTAssertNil(host.itemIndex(forCarouselIndex: -1, itemCount: 3))
    }

    // MARK: - A leading pasteboard card shifts every real item's index by one

    func testPasteboardCardShiftsIndexByOne() {
        let host = TestHost()
        host.pasteboardCardShowing = true
        XCTAssertEqual(host.cardOffset, 1)
        XCTAssertEqual(host.itemIndex(forCarouselIndex: 1, itemCount: 3), 0,
                       "carousel index 1 is the FIRST real item once the pasteboard card is showing")
        XCTAssertEqual(host.itemIndex(forCarouselIndex: 3, itemCount: 3), 2)
    }

    func testPasteboardCardOwnPositionIsNotAnItemIndex() {
        let host = TestHost()
        host.pasteboardCardShowing = true
        XCTAssertNil(host.itemIndex(forCarouselIndex: 0, itemCount: 3),
                    "carousel index 0 IS the pasteboard card itself, not item 0")
    }

    func testPasteboardCardOutOfRangeIndexIsNil() {
        let host = TestHost()
        host.pasteboardCardShowing = true
        XCTAssertNil(host.itemIndex(forCarouselIndex: 4, itemCount: 3))
    }

    // MARK: - Toggling the pasteboard card changes the offset live

    func testOffsetTracksThePasteboardCardFlagAsItChanges() {
        let host = TestHost()
        XCTAssertEqual(host.itemIndex(forCarouselIndex: 0, itemCount: 2), 0)
        host.pasteboardCardShowing = true
        XCTAssertEqual(host.itemIndex(forCarouselIndex: 0, itemCount: 2), nil)
        XCTAssertEqual(host.itemIndex(forCarouselIndex: 1, itemCount: 2), 0)
        host.pasteboardCardShowing = false
        XCTAssertEqual(host.itemIndex(forCarouselIndex: 0, itemCount: 2), 0)
    }

    // MARK: - Empty item list

    func testEmptyItemListHasNoValidIndex() {
        let host = TestHost()
        XCTAssertNil(host.itemIndex(forCarouselIndex: 0, itemCount: 0))
        host.pasteboardCardShowing = true
        XCTAssertNil(host.itemIndex(forCarouselIndex: 1, itemCount: 0))
    }

    // MARK: - Pasteboard privacy and temporary-media policy

    func testPasteboardReadTimingUsesOnlyConspicuouslyLongReadsAsPromptHint() {
        XCTAssertFalse(PasteboardReadTiming.likelyPresentedPermissionPrompt(elapsed: 0))
        XCTAssertFalse(PasteboardReadTiming.likelyPresentedPermissionPrompt(elapsed: 0.249))
        XCTAssertTrue(PasteboardReadTiming.likelyPresentedPermissionPrompt(elapsed: 0.25))
        XCTAssertTrue(PasteboardReadTiming.likelyPresentedPermissionPrompt(elapsed: 2))
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

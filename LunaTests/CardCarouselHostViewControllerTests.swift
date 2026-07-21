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

import XCTest
@testable import Luna

final class CardCarouselHostViewControllerTests: XCTestCase {

    /// Flips `hasLeadingPasteboardCard` on demand, mirroring how a real
    /// subclass reflects its own pasteboard state.
    private final class TestHost: CardCarouselHostViewController {
        var pasteboardCardShowing = false
        override var hasLeadingPasteboardCard: Bool { pasteboardCardShowing }
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
}

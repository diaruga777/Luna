//
//  ReaderScrollPositionTests.swift
//  LunaTests
//


import LunaModels
import XCTest

final class ReaderScrollPositionTests: XCTestCase {
    func testOffsetsThroughTitleHeaderNormalizeToTop() {
        XCTAssertEqual(
            ReaderScrollPosition.normalizedForPersistence(-72, titleHeaderHeight: 96), 0)
        XCTAssertEqual(
            ReaderScrollPosition.normalizedForPersistence(0, titleHeaderHeight: 96), 0)
        XCTAssertEqual(
            ReaderScrollPosition.normalizedForPersistence(95.9, titleHeaderHeight: 96), 0)
        XCTAssertEqual(
            ReaderScrollPosition.normalizedForPersistence(96, titleHeaderHeight: 96), 0)
    }

    func testOffsetPastTitleHeaderIsPreservedExactly() {
        XCTAssertEqual(
            ReaderScrollPosition.normalizedForPersistence(96.1, titleHeaderHeight: 96), 96.1)
    }

    func testPersistedTopRestoresToInsetRelativeUIKitTop() {
        XCTAssertEqual(
            ReaderScrollPosition.contentOffsetForRestoration(0, adjustedTopInset: 96), -96)
    }

    func testNonzeroPersistedOffsetRestoresExactly() {
        XCTAssertEqual(
            ReaderScrollPosition.contentOffsetForRestoration(96.1, adjustedTopInset: 96), 96.1)
    }

    // MARK: - Title handoff

    func testPinnedTitleTakesOverOnlyAfterScrollingCopyHasFullyLeft() {
        // Still partly onscreen: the copy in the content keeps the title.
        XCTAssertFalse(
            ReaderScrollPosition.pinnedTitleOwnsTitle(
                wasPinned: false, distanceFromTop: 95, titleHeaderHeight: 96))
        XCTAssertFalse(
            ReaderScrollPosition.pinnedTitleOwnsTitle(
                wasPinned: false, distanceFromTop: 97, titleHeaderHeight: 96))
        XCTAssertTrue(
            ReaderScrollPosition.pinnedTitleOwnsTitle(
                wasPinned: false, distanceFromTop: 97.5, titleHeaderHeight: 96))
    }

    func testPinnedTitleHoldsThroughTheScrollingCopysApproach() {
        // Scrolling back up: the pinned copy stays parked over every offset the
        // scrolling copy travels through, so nothing blinks out mid-approach.
        for distance in stride(from: 96.0, through: 1.0, by: -5) {
            XCTAssertTrue(
                ReaderScrollPosition.pinnedTitleOwnsTitle(
                    wasPinned: true, distanceFromTop: distance, titleHeaderHeight: 96),
                "released the title at \(distance)")
        }
    }

    func testPinnedTitleHandsBackWhereTheTwoCopiesCoincide() {
        XCTAssertFalse(
            ReaderScrollPosition.pinnedTitleOwnsTitle(
                wasPinned: true, distanceFromTop: 0, titleHeaderHeight: 96))
        // Overscroll past the top pulls the scrolling copy down with the page.
        XCTAssertFalse(
            ReaderScrollPosition.pinnedTitleOwnsTitle(
                wasPinned: true, distanceFromTop: -40, titleHeaderHeight: 96))
    }
}

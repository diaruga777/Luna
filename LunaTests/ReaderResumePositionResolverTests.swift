//
//  ReaderResumePositionResolverTests.swift
//  LunaTests
//

import LunaModels
import XCTest
@testable import Luna

/// Verifies the pure carry-over logic: opening/closing the scroll reader must
/// not move the carried word index; only a real scroll may.
final class ReaderResumePositionResolverTests: XCTestCase {

    // MARK: - No-op guarantee (the bug being fixed)

    func testNoScrollReturnsResumeIndexUnchanged() {
        let reported = ReaderResumePositionResolver.reportedWordIndex(
            resumeIndex: 137,
            scrolledPastThreshold: false,
            firstFullyVisibleIndex: 142)  // a slightly different recomputed index
        XCTAssertEqual(reported, 137, "Must carry the incoming index, not the recomputed visible one.")
    }

    func testRepeatedOpenCloseNeverDriftsTheIndex() {
        // Simulate paging back and forth: each "open" recomputes a slightly
        // different first-fully-visible index, but with no scroll the reported
        // index must stay exactly the carried value every time.
        var carried = 200
        for drift in [201, 199, 203, 198, 205] {
            carried = ReaderResumePositionResolver.reportedWordIndex(
                resumeIndex: carried,
                scrolledPastThreshold: false,
                firstFullyVisibleIndex: drift) ?? -1
            XCTAssertEqual(carried, 200, "Index drifted across a switch with no real movement.")
        }
    }

    // MARK: - Scroll past threshold

    func testScrolledPastThresholdReportsVisibleIndex() {
        let reported = ReaderResumePositionResolver.reportedWordIndex(
            resumeIndex: 50,
            scrolledPastThreshold: true,
            firstFullyVisibleIndex: 88)
        XCTAssertEqual(reported, 88)
    }

    func testScrolledButVisibleIndexUncomputableFallsBackToResume() {
        let reported = ReaderResumePositionResolver.reportedWordIndex(
            resumeIndex: 50,
            scrolledPastThreshold: true,
            firstFullyVisibleIndex: nil)
        XCTAssertEqual(reported, 50)
    }

    // MARK: - Scroll threshold geometry

    func testOffsetBelowThresholdIsNotAScroll() {
        let belowThreshold = ReaderResumePositionResolver.scrolledPastThresholdPoints - 1
        XCTAssertFalse(ReaderResumePositionResolver.scrolledPastThreshold(
            openOffsetY: 100, currentOffsetY: 100 + belowThreshold))
        // Direction doesn't matter — small jitter either way is not a scroll.
        XCTAssertFalse(ReaderResumePositionResolver.scrolledPastThreshold(
            openOffsetY: 100, currentOffsetY: 100 - belowThreshold))
    }

    func testOffsetAtOrPastThresholdIsAScroll() {
        let threshold = ReaderResumePositionResolver.scrolledPastThresholdPoints
        XCTAssertTrue(ReaderResumePositionResolver.scrolledPastThreshold(
            openOffsetY: 100, currentOffsetY: 100 + threshold))
        XCTAssertTrue(ReaderResumePositionResolver.scrolledPastThreshold(
            openOffsetY: 100, currentOffsetY: 100 - threshold))
    }

    // MARK: - Fresh open (no carried index) still resumes from where you are

    func testFreshOpenWithoutCarriedIndexIsHandledByCaller() {
        // When there's no carried index the resolver simply echoes nil; the
        // scroll reader's caller substitutes the visible position so the first
        // switch resumes correctly. Documented here as the contract.
        let reported = ReaderResumePositionResolver.reportedWordIndex(
            resumeIndex: nil,
            scrolledPastThreshold: false,
            firstFullyVisibleIndex: 5)
        XCTAssertNil(reported)
    }
}

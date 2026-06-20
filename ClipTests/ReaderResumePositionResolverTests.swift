//
//  ReaderResumePositionResolverTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

/// Verifies the pure carry-over logic: opening/closing the scroll reader must
/// not move the carried word index; only a real scroll or a confirmed
/// multi-word gaze lock may.
final class ReaderResumePositionResolverTests: XCTestCase {

    // MARK: - No-op guarantee (the bug being fixed)

    func testNoScrollNoGazeReturnsResumeIndexUnchanged() {
        let reported = ReaderResumePositionResolver.reportedWordIndex(
            resumeIndex: 137,
            scrolledPastThreshold: false,
            confirmedGazeIndex: nil,
            firstFullyVisibleIndex: 142)  // a slightly different recomputed index
        XCTAssertEqual(reported, 137, "Must carry the incoming index, not the recomputed visible one.")
    }

    func testRepeatedOpenCloseNeverDriftsTheIndex() {
        // Simulate paging back and forth: each "open" recomputes a slightly
        // different first-fully-visible index, but with no scroll and no gaze
        // the reported index must stay exactly the carried value every time.
        var carried = 200
        for drift in [201, 199, 203, 198, 205] {
            carried = ReaderResumePositionResolver.reportedWordIndex(
                resumeIndex: carried,
                scrolledPastThreshold: false,
                confirmedGazeIndex: nil,
                firstFullyVisibleIndex: drift) ?? -1
            XCTAssertEqual(carried, 200, "Index drifted across a switch with no real movement.")
        }
    }

    // MARK: - Scroll past threshold

    func testScrolledPastThresholdReportsVisibleIndex() {
        let reported = ReaderResumePositionResolver.reportedWordIndex(
            resumeIndex: 50,
            scrolledPastThreshold: true,
            confirmedGazeIndex: nil,
            firstFullyVisibleIndex: 88)
        XCTAssertEqual(reported, 88)
    }

    func testScrolledPastThresholdWinsOverGaze() {
        let reported = ReaderResumePositionResolver.reportedWordIndex(
            resumeIndex: 50,
            scrolledPastThreshold: true,
            confirmedGazeIndex: 70,
            firstFullyVisibleIndex: 88)
        XCTAssertEqual(reported, 88, "A deliberate scroll should win over a gaze lock.")
    }

    func testScrolledButVisibleIndexUncomputableFallsBackToResume() {
        let reported = ReaderResumePositionResolver.reportedWordIndex(
            resumeIndex: 50,
            scrolledPastThreshold: true,
            confirmedGazeIndex: nil,
            firstFullyVisibleIndex: nil)
        XCTAssertEqual(reported, 50)
    }

    // MARK: - Confirmed gaze

    func testConfirmedGazeReportsGazeIndexWhenNotScrolled() {
        let reported = ReaderResumePositionResolver.reportedWordIndex(
            resumeIndex: 10,
            scrolledPastThreshold: false,
            confirmedGazeIndex: 64,
            firstFullyVisibleIndex: 12)
        XCTAssertEqual(reported, 64)
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

    // MARK: - Gaze lock gate (stability)

    func testSingleGazeSampleDoesNotConfirm() {
        var gate = GazeLockGate()
        gate.record(42)
        XCTAssertNil(gate.confirmedIndex, "One sample must never count as a lock.")
    }

    func testFewerThanRequiredConsecutiveWordsDoNotConfirm() {
        var gate = GazeLockGate(wordsNeeded: 4)
        gate.record(10)
        gate.record(11)
        gate.record(12)
        XCTAssertNil(gate.confirmedIndex)
    }

    func testRequiredConsecutiveDistinctWordsConfirm() {
        var gate = GazeLockGate(wordsNeeded: 4)
        gate.record(10)
        gate.record(11)
        gate.record(12)
        gate.record(13)
        XCTAssertEqual(gate.confirmedIndex, 13, "A steady run across several words is a real lock.")
    }

    func testDwellingOnOneWordDoesNotConfirm() {
        // A noisy estimate stuck on the same word repeating is NOT a multi-word
        // lock and must not move the carried position.
        var gate = GazeLockGate(wordsNeeded: 4)
        for _ in 0..<10 { gate.record(42) }
        XCTAssertNil(gate.confirmedIndex)
    }

    func testDefaultGateUsesResolverConstant() {
        var gate = GazeLockGate()
        for index in 0..<(ReaderResumePositionResolver.consecutiveGazeWordsForLock - 1) {
            gate.record(index)
        }
        XCTAssertNil(gate.confirmedIndex)
        gate.record(ReaderResumePositionResolver.consecutiveGazeWordsForLock - 1)
        XCTAssertNotNil(gate.confirmedIndex)
    }

    // MARK: - Fresh open (no carried index) still resumes from where you are

    func testFreshOpenWithoutCarriedIndexIsHandledByCaller() {
        // When there's no carried index the resolver simply echoes nil; the
        // scroll reader's caller substitutes the visible/gaze position so the
        // first switch resumes correctly. Documented here as the contract.
        let reported = ReaderResumePositionResolver.reportedWordIndex(
            resumeIndex: nil,
            scrolledPastThreshold: false,
            confirmedGazeIndex: nil,
            firstFullyVisibleIndex: 5)
        XCTAssertNil(reported)
    }
}

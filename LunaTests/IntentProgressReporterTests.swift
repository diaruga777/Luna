//
//  IntentProgressReporterTests.swift
//  LunaTests
//

import LunaIngest
import LunaIntents
import LunaMediaDownload
import XCTest
@testable import Luna

/// The extended-runtime plumbing: progress must always move (the system revokes
/// the runtime extension if it stalls) without ever claiming a stage finished
/// early, and the system-progress hand-off must be scoped to the intent.
final class IntentProgressReporterTests: XCTestCase {

    func testStartsAtZeroInTheSavingStage() {
        XCTAssertEqual(IntentProgressReporter().fraction, 0)
    }

    func testEveryTickMovesTheValue() {
        let reporter = IntentProgressReporter()
        var previous = reporter.fraction
        for _ in 0..<20 {
            reporter.tick()
            XCTAssertGreaterThan(
                reporter.fraction, previous, "a stalled progress gets the runtime cancelled")
            previous = reporter.fraction
        }
    }

    func testTicksNeverLeaveTheCurrentStageBand() {
        let reporter = IntentProgressReporter()
        for _ in 0..<500 { reporter.tick() }
        // Saving tops out below the downloading band — a save that hasn't
        // finished must not report the download as started.
        let band = IntentProgressReporter.Stage.saving.band
        XCTAssertLessThanOrEqual(reporter.fraction, band.upperBound)
        // Expressed against the band, not a literal: ticks close on its top
        // asymptotically, and the split between stages is free to change.
        XCTAssertGreaterThan(
            reporter.fraction,
            band.lowerBound + (band.upperBound - band.lowerBound) * 0.9)
    }

    /// The save is a sliver on purpose. It is fast, and the bytes are the only
    /// part with an honest measure, so the transfer owns essentially the whole
    /// bar. When the save had half of it, a failed save looked to the user like a
    /// download that died halfway through.
    func testSaveIsASliverAndTheTransferOwnsTheBar() {
        let saving = IntentProgressReporter.Stage.saving.band
        let downloading = IntentProgressReporter.Stage.downloading.band
        XCTAssertLessThanOrEqual(saving.upperBound, 0.02)
        XCTAssertGreaterThan(downloading.upperBound - downloading.lowerBound, 0.9)
    }

    // MARK: - Real byte counts

    func testByteCountsAreNilUntilTheSizeIsKnown() {
        let reporter = IntentProgressReporter()
        reporter.enter(.downloading)
        XCTAssertNil(reporter.byteCounts)
        reporter.setReceivedBytes(1_024)
        XCTAssertNil(reporter.byteCounts, "received bytes alone can't scale a bar")
        reporter.setExpectedBytes(4_096)
        XCTAssertEqual(reporter.byteCounts?.expected, 4_096)
    }

    func testByteProgressAdvancesTheFractionWithinTheDownloadBand() {
        let reporter = IntentProgressReporter()
        reporter.enter(.downloading)
        reporter.setExpectedBytes(1_000)
        reporter.setReceivedBytes(500)
        let band = IntentProgressReporter.Stage.downloading.band
        let midpoint = band.lowerBound + (band.upperBound - band.lowerBound) / 2
        XCTAssertEqual(reporter.fraction, midpoint, accuracy: 0.0001)
        XCTAssertEqual(reporter.byteCounts?.received, 500)
    }

    func testByteCountsNeverExceedTheExpectedSizeOrGoBackward() {
        let reporter = IntentProgressReporter()
        reporter.setExpectedBytes(1_000)
        reporter.setReceivedBytes(900)
        reporter.setReceivedBytes(100)
        XCTAssertEqual(reporter.byteCounts?.received, 900, "progress must not rewind")
        reporter.setReceivedBytes(5_000)
        XCTAssertEqual(
            reporter.byteCounts?.received, 1_000,
            "a bar can't report more bytes than the file has")
    }

    func testZeroOrMissingExpectedSizeIsIgnored() {
        let reporter = IntentProgressReporter()
        reporter.setExpectedBytes(nil)
        reporter.setExpectedBytes(0)
        XCTAssertNil(reporter.byteCounts, "a zero total would divide by zero")
    }

    func testEnteringAStageSnapsForwardToItsFloor() {
        let reporter = IntentProgressReporter()
        reporter.enter(.downloading)
        XCTAssertEqual(
            reporter.fraction, IntentProgressReporter.Stage.downloading.band.lowerBound)
        reporter.enter(.finishing)
        XCTAssertEqual(
            reporter.fraction, IntentProgressReporter.Stage.finishing.band.lowerBound)
    }

    func testProgressNeverGoesBackward() {
        let reporter = IntentProgressReporter()
        reporter.enter(.finishing)
        let advanced = reporter.fraction
        reporter.enter(.saving)
        XCTAssertEqual(reporter.fraction, advanced)
    }

    func testStageBandsAreContiguousAndCoverTheWholeRange() {
        XCTAssertEqual(IntentProgressReporter.Stage.saving.band.lowerBound, 0)
        XCTAssertEqual(
            IntentProgressReporter.Stage.saving.band.upperBound,
            IntentProgressReporter.Stage.downloading.band.lowerBound)
        XCTAssertEqual(
            IntentProgressReporter.Stage.downloading.band.upperBound,
            IntentProgressReporter.Stage.finishing.band.lowerBound)
        XCTAssertEqual(IntentProgressReporter.Stage.finishing.band.upperBound, 1)
    }

    // MARK: - Who owns the progress UI

    func testLunaOwnsTheLiveActivityByDefault() {
        XCTAssertFalse(LiveMediaDownloadManager.systemProvidesProgressUI)
    }

    func testSystemProgressOwnershipIsScopedToTheBoundOperation() async {
        await LiveMediaDownloadManager.$systemProvidesProgressUI.withValue(true) {
            XCTAssertTrue(LiveMediaDownloadManager.systemProvidesProgressUI)
        }
        // Outside the binding an in-app save still gets Luna's own activity.
        XCTAssertFalse(LiveMediaDownloadManager.systemProvidesProgressUI)
    }

    // MARK: - How long a save press may wait

    func testExtendedRuntimeWaitsPastThePipelinesOwnHardTimeout() {
        // The whole point of the longer budget: the ingest pipeline always
        // resolves within its own timeout, so waiting past it makes the race a
        // backstop and a failed fetch gets REPORTED instead of timing out into a
        // reported success.
        XCTAssertGreaterThan(
            IntentSaveTimeout.extendedRuntime, IngestPipeline.processTimeout)
        XCTAssertGreaterThan(IntentSaveTimeout.extendedRuntime, IntentSaveTimeout.standard)
    }

    func testStandardBudgetLeavesRoomForTheRestOfTheIntent() {
        // ~30 s total, and the save is only the first leg — the media handoff
        // (preflight HEAD + transfer) still has to fit after it.
        XCTAssertEqual(IntentSaveTimeout.standard, 12)
        XCTAssertLessThan(IntentSaveTimeout.standard, 30)
    }

    func testProvideContextUsesTwentySecondsOfTheNormalBudget() {
        XCTAssertEqual(IntentSaveTimeout.provideContext, 20)
        XCTAssertLessThan(IntentSaveTimeout.provideContext, 30)
    }

    func testSaveIntentTakesTheRuntimesBudgetNotTheDefault() {
        // Proves the concrete-type override actually shadows
        // `CaptureIntentRuntime`'s default. If it silently stopped winning, both
        // intents would quietly keep racing 12 s under the extended runtime —
        // invisible at runtime, so it gets a test.
        let expected: TimeInterval
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            expected = IntentSaveTimeout.extendedRuntime
        } else {
            expected = IntentSaveTimeout.standard
        }
        #else
        expected = IntentSaveTimeout.standard
        #endif
        XCTAssertEqual(SaveIntent().captureSaveTimeout, expected)
        XCTAssertEqual(CaptureIntentExtendedRuntime.saveTimeout, expected)
    }

    func testSystemProgressIsOnlyClaimedWhereTheRuntimeExistsToDriveIt() {
        // The flag exists to mirror `LongRunningIntent` availability: claiming it
        // without the extended runtime would suppress Luna's activity and leave
        // NO progress UI at all.
        if #available(iOS 27.0, *) {
            // Xcode 26.2 archives compile the fallback even on iOS 27.
            #if compiler(>=6.4)
            XCTAssertTrue(CaptureIntentExtendedRuntime.isAvailable)
            #else
            XCTAssertFalse(CaptureIntentExtendedRuntime.isAvailable)
            #endif
        } else {
            XCTAssertFalse(CaptureIntentExtendedRuntime.isAvailable)
        }
    }
}

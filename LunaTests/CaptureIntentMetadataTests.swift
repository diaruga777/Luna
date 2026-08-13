//
//  CaptureIntentMetadataTests.swift
//  LunaTests
//

import AppIntents
import LunaIntents
import LunaModels
import LunaReadingList
import UniformTypeIdentifiers
import XCTest
@testable import Luna

final class CaptureIntentMetadataTests: XCTestCase {

    func testSaveCheckpointRoundTripsAsOpaqueJSON() throws {
        let date = Date(timeIntervalSinceReferenceDate: 123_456)
        let prepared = SavesIngestor.PreparedSavePress(
            itemID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            urlString: "https://example.com/article",
            action: .saveNew,
            isDoubleSave: false,
            doubleSaveActionSurface: .reader,
            attemptDate: date)
        let media = IntentMediaCheckpoint(
            asset: MediaAsset(
                url: URL(string: "https://cdn.example.com/video.mp4")!,
                kind: .video,
                thumbnailURL: URL(string: "https://cdn.example.com/poster.jpg"),
                estimatedByteCount: 42_000),
            expectedByteCount: 43_000)
        let value = CaptureIntentMetadata(
            phase: .download,
            currentApp: "Safari",
            resolvedURLString: prepared.urlString,
            isDoubleSave: false,
            preparedSave: prepared,
            media: media)

        let encoded = try XCTUnwrap(value.opaqueString)
        XCTAssertTrue(encoded.hasPrefix("{"))
        XCTAssertEqual(CaptureIntentMetadata.decode(encoded), value)
    }

    /// A NEWER schema than this build knows falls back. Older ones deliberately
    /// do not — the schema is additive by rule, so a v1 checkpoint held in a
    /// Shortcut across an app update still describes a resumable save
    /// (`ProductComparisonIntentTests` pins that side).
    func testUnknownSchemaFallsBackInsteadOfPartiallyResuming() throws {
        let value = CaptureIntentMetadata(
            phase: .screenshot, currentApp: "Instagram")
        let encoded = try XCTUnwrap(value.opaqueString)
            .replacingOccurrences(
                of: "\"schemaVersion\":\(CaptureIntentMetadata.currentSchemaVersion)",
                with: "\"schemaVersion\":999")

        XCTAssertNil(CaptureIntentMetadata.decode(encoded))
    }

    func testEmptyAndMalformedMetadataFallBack() {
        XCTAssertNil(CaptureIntentMetadata.decode(nil))
        XCTAssertNil(CaptureIntentMetadata.decode(""))
        XCTAssertNil(CaptureIntentMetadata.decode("not json"))
    }

    func testOutcomeVocabularyMatchesShortcutBranches() {
        XCTAssertEqual(ProvideContextOutcome.done.rawValue, "done")
        XCTAssertEqual(ProvideContextOutcome.screenshot.rawValue, "screenshot")
        XCTAssertEqual(ProvideContextOutcome.download.rawValue, "download")
        XCTAssertEqual(ProvideContextOutcome.unhandled.rawValue, "unhandled")
    }

    func testResultEntityEnforcesOutcomePayloadContract() {
        let file = IntentFile(data: Data([0x01]), filename: "media.bin", type: .data)

        let done = ProvideContextResultEntity(
            outcome: .done, media: file, metadata: "must be discarded")
        XCTAssertNotNil(done.media)
        XCTAssertNil(done.metadata)

        let screenshot = ProvideContextResultEntity(
            outcome: .screenshot, media: file, metadata: "checkpoint")
        XCTAssertNil(screenshot.media)
        XCTAssertEqual(screenshot.metadata, "checkpoint")

        let unhandled = ProvideContextResultEntity(
            outcome: .unhandled, media: file, metadata: "must be discarded")
        XCTAssertNil(unhandled.media)
        XCTAssertNil(unhandled.metadata)
    }

    func testFastPathReturnsCompletedWork() async throws {
        let value: Int = try await CaptureIntentFastPath.run(timeout: 1) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testFastPathTimeoutCancelsLosingWork() async {
        let cancelled = expectation(description: "losing work cancelled")

        do {
            let _: Int = try await CaptureIntentFastPath.run(timeout: 0.01) {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    if Task.isCancelled { cancelled.fulfill() }
                    throw error
                }
                return 42
            }
            XCTFail("Expected the fast path to time out")
        } catch CaptureIntentFastPathError.timedOut {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await fulfillment(of: [cancelled], timeout: 1)
    }
}

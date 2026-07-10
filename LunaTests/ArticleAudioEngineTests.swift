//
//  ArticleAudioEngineTests.swift
//  LunaTests
//

import AVFoundation
import LunaAudioPlayback
import XCTest

/// `ArticleAudioEngine` tests run entirely in `AVAudioEngine`'s offline
/// manual-rendering mode (no real audio device needed, deterministic): they
/// schedule synthetic silent buffers (never real synthesis) and drive the
/// graph forward with `renderOffline(maxFrames:)`, asserting on the playhead,
/// scheduling completion, rate pinning, and the low-water-mark signal.
final class ArticleAudioEngineTests: XCTestCase {

    private let sampleRate: Double = 44100

    private var canonicalFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    private func makeEngine() throws -> ArticleAudioEngine {
        try ArticleAudioEngine(format: canonicalFormat, manualRendering: true)
    }

    private func silentBuffer(frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        return buffer
    }

    /// A `RenderedSegment` built from synthetic silent buffers (no real
    /// synthesis) totaling `totalFrames` split across `bufferCount` buffers.
    private func makeSegment(blockIndex: Int, totalFrames: Int, bufferCount: Int = 3) -> RenderedSegment {
        let perBuffer = totalFrames / bufferCount
        var buffers: [AVAudioPCMBuffer] = []
        var remaining = totalFrames
        for i in 0..<bufferCount {
            let count = (i == bufferCount - 1) ? remaining : perBuffer
            buffers.append(silentBuffer(frames: AVAudioFrameCount(count)))
            remaining -= count
        }
        return RenderedSegment(
            blockIndex: blockIndex, buffers: buffers, wordMarkers: [],
            duration: Double(totalFrames) / sampleRate, format: canonicalFormat)
    }

    /// Drives manual rendering forward by roughly `seconds` of audio, in
    /// chunks, yielding to the run loop between chunks so main-queue-dispatched
    /// completion handlers actually run before the next assertion.
    private func pumpRendering(_ engine: ArticleAudioEngine, seconds: Double) async throws {
        var framesRemaining = Int((seconds * sampleRate).rounded(.up))
        let chunk: AVAudioFrameCount = 4096
        while framesRemaining > 0 {
            _ = try engine.renderOffline(maxFrames: chunk)
            framesRemaining -= Int(chunk)
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    // MARK: - Basics

    func testEngineStartsAndIsPlayingAfterInit() throws {
        let engine = try makeEngine()
        XCTAssertTrue(engine.isPlaying)
    }

    func testPauseStopsIsPlayingAndPlayResumes() throws {
        let engine = try makeEngine()
        engine.pause()
        XCTAssertFalse(engine.isPlaying)
        engine.play()
        XCTAssertTrue(engine.isPlaying)
    }

    func testDefaultRateIsUnity() throws {
        let engine = try makeEngine()
        XCTAssertEqual(engine.rate, 1.0)
    }

    func testSettingRatePersists() throws {
        let engine = try makeEngine()
        engine.rate = 1.5
        XCTAssertEqual(engine.rate, 1.5)
    }

    // MARK: - Scheduling & playhead

    func testSchedulingSegmentAdvancesPlayhead() async throws {
        let engine = try makeEngine()
        let segment = makeSegment(blockIndex: 0, totalFrames: Int(sampleRate)) // ~1s

        let expectation = expectation(description: "segment completion")
        engine.schedule(segment) { expectation.fulfill() }

        try await pumpRendering(engine, seconds: 1.2)
        await fulfillment(of: [expectation], timeout: 5)

        XCTAssertGreaterThan(engine.currentTime, 0.5)
    }

    func testResetAndScheduleRebasesPlayhead() throws {
        let engine = try makeEngine()
        engine.resetAndSchedule(from: 42.0)
        // Immediately after a rebase (before any new rendering progress),
        // currentTime should read back at (approximately) the rebase point.
        XCTAssertEqual(engine.currentTime, 42.0, accuracy: 0.05)
    }

    func testSchedulingEmptySegmentCompletesImmediatelyWithoutThrowing() async throws {
        let engine = try makeEngine()
        let emptySegment = RenderedSegment(
            blockIndex: 0, buffers: [], wordMarkers: [], duration: 0, format: canonicalFormat)

        let expectation = expectation(description: "empty segment completion")
        engine.schedule(emptySegment) { expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: 2)
    }

    // MARK: - Rate pinning

    func testPinnedToNaturalRestoresPriorRateAfterCompletion() async throws {
        let engine = try makeEngine()
        engine.rate = 1.5
        let segment = makeSegment(blockIndex: 0, totalFrames: Int(sampleRate * 0.3))

        let expectation = expectation(description: "announcement completion")
        engine.schedule(segment, rateMode: .pinnedToNatural) { expectation.fulfill() }

        // Pinning happens synchronously at schedule time.
        XCTAssertEqual(engine.rate, 1.0)

        try await pumpRendering(engine, seconds: 0.5)
        await fulfillment(of: [expectation], timeout: 5)

        XCTAssertEqual(engine.rate, 1.5, "rate must be restored once the pinned segment has been heard")
    }

    func testFollowsUserRateDoesNotChangeRate() throws {
        let engine = try makeEngine()
        engine.rate = 1.2
        let segment = makeSegment(blockIndex: 0, totalFrames: 1000)
        engine.schedule(segment, rateMode: .followsUserRate)
        XCTAssertEqual(engine.rate, 1.2)
    }

    // MARK: - Low-water mark

    func testNeedsMoreAudioFiresWhenQueuedDurationDropsBelowMark() async throws {
        let engine = try makeEngine()
        engine.lowWaterMark = 5 // seconds

        let expectation = expectation(description: "low water mark signal")
        engine.needsMoreAudioHandler = { expectation.fulfill() }

        // Schedule ~1s total — below the 5s mark as soon as it's consumed.
        let segment = makeSegment(blockIndex: 0, totalFrames: Int(sampleRate))
        engine.schedule(segment)

        try await pumpRendering(engine, seconds: 1.2)
        await fulfillment(of: [expectation], timeout: 5)
    }

    func testNeedsMoreAudioDoesNotFireWhileWellAboveMark() throws {
        let engine = try makeEngine()
        engine.lowWaterMark = 1 // second

        var fired = false
        engine.needsMoreAudioHandler = { fired = true }

        // Scheduling ~10s keeps queued duration well above the 1s mark.
        let segment = makeSegment(blockIndex: 0, totalFrames: Int(sampleRate * 10))
        engine.schedule(segment)

        XCTAssertFalse(fired)
    }

    // MARK: - Tones

    func testSchedulingBundledToneDoesNotThrow() throws {
        let engine = try makeEngine()
        XCTAssertNoThrow(try engine.scheduleTone(.transition))
    }

    func testSchedulingBundledToneCompletes() async throws {
        let engine = try makeEngine()
        let expectation = expectation(description: "tone completion")
        try engine.scheduleTone(.transition) { expectation.fulfill() }
        try await pumpRendering(engine, seconds: 1.0)
        await fulfillment(of: [expectation], timeout: 5)
    }

    // MARK: - Manual rendering guard

    func testRenderOfflineThrowsWhenNotInManualRenderingMode() throws {
        let engine = try ArticleAudioEngine(format: canonicalFormat, manualRendering: false)
        XCTAssertThrowsError(try engine.renderOffline())
    }
}

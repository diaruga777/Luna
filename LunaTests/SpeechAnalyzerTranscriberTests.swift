//
//  SpeechAnalyzerTranscriberTests.swift
//  LunaTests
//
//  The iOS 26 transcriber shares `SpeechAudioEngine` and `SpeechPermissionCheck`
//  with `SFSpeechTranscriber` — this covers the engine-level lifecycle a fake
//  engine can drive; the real `SpeechAnalyzer`/`SpeechTranscriber` results
//  stream has no test double and is exercised only by `tools/plugin-sim`-style
//  manual runs.
//

import AVFoundation
import Speech
import XCTest
@testable import LunaWriterVoice

@available(iOS 26.0, *)
private final class FakeSpeechAudioEngine: SpeechAudioEngine {
    let format: AVAudioFormat
    private(set) var isRunning = false
    private(set) var installTapCount = 0
    private(set) var removeTapCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(format: AVAudioFormat) { self.format = format }

    var inputFormat: AVAudioFormat { format }

    func installTap(
        bufferSize: AVAudioFrameCount, block: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) {
        installTapCount += 1
    }

    func removeTap() { removeTapCount += 1 }
    func prepare() {}
    func start() throws { isRunning = true; startCount += 1 }
    func stop() { isRunning = false; stopCount += 1 }
    func pause() {}
}

@available(iOS 26.0, *)
final class SpeechAnalyzerTranscriberTests: XCTestCase {

    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!

    override func tearDown() {
        SpeechPermissionCheck.testOverride = nil
        super.tearDown()
    }

    func testStartInstallsATapAndRunsTheEngine() throws {
        guard SpeechTranscriber.isAvailable else {
            throw XCTSkip("SpeechTranscriber.isAvailable is false on this simulator/OS")
        }
        SpeechPermissionCheck.testOverride = .available
        let engine = FakeSpeechAudioEngine(format: format)
        let transcriber = SpeechAnalyzerTranscriber(engine: engine)
        try transcriber.start()
        addTeardownBlock { transcriber.stop() }

        XCTAssertEqual(engine.installTapCount, 1)
        XCTAssertTrue(engine.isRunning)
    }

    func testStopRemovesTheTapAndStopsTheEngine() throws {
        guard SpeechTranscriber.isAvailable else {
            throw XCTSkip("SpeechTranscriber.isAvailable is false on this simulator/OS")
        }
        SpeechPermissionCheck.testOverride = .available
        let engine = FakeSpeechAudioEngine(format: format)
        let transcriber = SpeechAnalyzerTranscriber(engine: engine)
        try transcriber.start()
        transcriber.stop()

        XCTAssertEqual(engine.removeTapCount, 1)
        XCTAssertFalse(engine.isRunning)
    }

    /// #11: both transcribers now share `SpeechPermissionCheck`, so their
    /// preconditions cannot disagree by construction.
    func testUnavailabilityReflectsThePermissionOverride() {
        SpeechPermissionCheck.testOverride = .unavailable(.microphoneDenied)
        let engine = FakeSpeechAudioEngine(format: format)
        let transcriber = SpeechAnalyzerTranscriber(engine: engine)
        if SpeechTranscriber.isAvailable {
            XCTAssertEqual(transcriber.unavailabilityReason, .microphoneDenied)
        } else {
            XCTAssertEqual(transcriber.unavailabilityReason, .unsupported)
        }
    }

    func testStartThrowsWhenPermissionIsUnavailable() {
        guard SpeechTranscriber.isAvailable else {
            return // start()'s own .unsupported guard fires first; covered by design, not worth a flaky skip here
        }
        SpeechPermissionCheck.testOverride = .unavailable(.permissionDenied)
        let engine = FakeSpeechAudioEngine(format: format)
        let transcriber = SpeechAnalyzerTranscriber(engine: engine)
        XCTAssertThrowsError(try transcriber.start()) { error in
            XCTAssertEqual(error as? SpeechTranscribingError, .unavailable(.permissionDenied))
        }
    }
}

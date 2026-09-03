//
//  SpeechTranscriberTests.swift
//  LunaTests
//
//  `SFSpeechTranscriber` against a fake `SpeechAudioEngine` and a fake
//  `SpeechRecognitionSessionMaking` — no real `AVAudioEngine`, no real
//  `SFSpeechRecognizer`, so these run the same on CI as on a Mac.
//

import AVFoundation
import XCTest
@testable import LunaWriterVoice

private final class FakeSpeechAudioEngine: SpeechAudioEngine {
    let format: AVAudioFormat
    private(set) var isRunning = false
    private(set) var installTapCount = 0
    private(set) var removeTapCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var pauseCount = 0
    private(set) var tapBlock: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

    init(format: AVAudioFormat) {
        self.format = format
    }

    var inputFormat: AVAudioFormat { format }

    func installTap(
        bufferSize: AVAudioFrameCount, block: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) {
        installTapCount += 1
        tapBlock = block
    }

    func removeTap() {
        removeTapCount += 1
        tapBlock = nil
    }

    func prepare() {}
    func start() throws { isRunning = true; startCount += 1 }
    func stop() { isRunning = false; stopCount += 1 }
    func pause() { pauseCount += 1 }
}

private final class FakeSpeechRecognitionSession: SpeechRecognitionSession {
    let onResult: (String, Bool) -> Void
    let onError: (Error?) -> Void
    private(set) var appendedBufferCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0

    init(onResult: @escaping (String, Bool) -> Void, onError: @escaping (Error?) -> Void) {
        self.onResult = onResult
        self.onError = onError
    }

    func append(_ buffer: AVAudioPCMBuffer) { appendedBufferCount += 1 }
    func finish() { finishCount += 1 }
    func cancel() { cancelCount += 1 }
}

private final class FakeSpeechRecognitionSessionMaker: SpeechRecognitionSessionMaking {
    private(set) var sessions: [FakeSpeechRecognitionSession] = []
    var madeCount: Int { sessions.count }

    func makeSession(
        onResult: @escaping (String, Bool) -> Void,
        onError: @escaping (Error?) -> Void
    ) -> SpeechRecognitionSession? {
        let session = FakeSpeechRecognitionSession(onResult: onResult, onError: onError)
        sessions.append(session)
        return session
    }
}

private struct FakeError: Error {}

final class SpeechTranscriberTests: XCTestCase {

    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!

    override func tearDown() {
        SpeechPermissionCheck.testOverride = nil
        super.tearDown()
    }

    private func makeTranscriber() -> (SFSpeechTranscriber, FakeSpeechAudioEngine, FakeSpeechRecognitionSessionMaker) {
        SpeechPermissionCheck.testOverride = .available
        let engine = FakeSpeechAudioEngine(format: format)
        let maker = FakeSpeechRecognitionSessionMaker()
        let transcriber = SFSpeechTranscriber(engine: engine, sessionMaker: maker)
        return (transcriber, engine, maker)
    }

    // MARK: - Lifecycle

    func testStartOpensOneSessionAndInstallsOneTap() throws {
        let (transcriber, engine, maker) = makeTranscriber()
        try transcriber.start()
        addTeardownBlock { transcriber.stop() }

        XCTAssertEqual(maker.madeCount, 1)
        XCTAssertEqual(engine.installTapCount, 1)
        XCTAssertTrue(engine.isRunning)
        XCTAssertNotNil(engine.tapBlock, "the tap must be captured, ready to receive buffers")
    }

    /// #1: `SFSpeechRecognitionTask` delivers `isFinal` once and then the
    /// task is done — this pins that the transcriber notices and opens a
    /// fresh session against the still-running engine, rather than going
    /// silent for the rest of read-along.
    func testAFinalResultOpensAFreshSessionRatherThanEndingCapture() throws {
        let (transcriber, engine, maker) = makeTranscriber()
        try transcriber.start()
        addTeardownBlock { transcriber.stop() }

        let first = maker.sessions[0]
        first.onResult("read this line", true)
        first.onError(nil) // SFSpeechRecognitionSessionMaker fires both on a final

        XCTAssertEqual(maker.madeCount, 2, "a final result must open a fresh session")
        XCTAssertTrue(engine.isRunning, "the engine itself must keep running across the restart")
        XCTAssertEqual(engine.stopCount, 0)
    }

    /// An error (not a final result) must restart the same way — the engine
    /// keeps running either way.
    func testARecognitionErrorAlsoOpensAFreshSession() throws {
        let (transcriber, _, maker) = makeTranscriber()
        try transcriber.start()
        addTeardownBlock { transcriber.stop() }

        maker.sessions[0].onError(FakeError())
        XCTAssertEqual(maker.madeCount, 2)
    }

    func testTheFinishedUtteranceReachesTheDelegate() throws {
        let (transcriber, _, maker) = makeTranscriber()
        let delegate = RecordingDelegate()
        transcriber.delegate = delegate
        try transcriber.start()
        addTeardownBlock { transcriber.stop() }

        maker.sessions[0].onResult("needs work", true)
        XCTAssertEqual(delegate.utterances, ["needs work"])
    }

    func testStopEndsTheSessionAndRemovesTheTap() throws {
        let (transcriber, engine, maker) = makeTranscriber()
        try transcriber.start()
        let session = maker.sessions[0]

        transcriber.stop()
        XCTAssertEqual(session.finishCount, 1)
        XCTAssertEqual(session.cancelCount, 1)
        XCTAssertEqual(engine.removeTapCount, 1)
        XCTAssertFalse(engine.isRunning)
    }

    func testStopIsSafeWhenNeverStarted() {
        let (transcriber, _, _) = makeTranscriber()
        transcriber.stop() // must not crash or throw
    }

    // MARK: - Interruption / configuration change

    /// #5: a route or engine configuration change invalidates the tap's
    /// format — the fix reinstalls it rather than leaving the transcriber
    /// silently deaf.
    func testAnEngineConfigurationChangeReinstallsTheTap() throws {
        let (transcriber, engine, _) = makeTranscriber()
        try transcriber.start()
        addTeardownBlock { transcriber.stop() }
        XCTAssertEqual(engine.installTapCount, 1)

        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)

        XCTAssertEqual(engine.removeTapCount, 1)
        XCTAssertEqual(engine.installTapCount, 2, "the tap must be reinstalled against the current format")
    }

    func testARouteChangeReinstallsTheTap() throws {
        let (transcriber, engine, _) = makeTranscriber()
        try transcriber.start()
        addTeardownBlock { transcriber.stop() }

        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil)
        XCTAssertEqual(engine.installTapCount, 2)
    }

    func testAConfigurationChangeAfterStopDoesNothing() throws {
        let (transcriber, engine, _) = makeTranscriber()
        try transcriber.start()
        transcriber.stop()
        let installsAtStop = engine.installTapCount

        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)
        XCTAssertEqual(engine.installTapCount, installsAtStop, "a stopped transcriber must not react")
    }

    func testAnInterruptionBeginPausesTheEngineWithoutTearingItDown() throws {
        let (transcriber, engine, _) = makeTranscriber()
        try transcriber.start()
        addTeardownBlock { transcriber.stop() }

        let note = Notification(
            name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
            ])
        NotificationCenter.default.post(note)
        XCTAssertEqual(engine.pauseCount, 1)
        XCTAssertEqual(engine.removeTapCount, 0, "a begin alone must not tear the tap down")
    }

    func testAnInterruptionEndWithShouldResumeReinstallsTheTap() throws {
        let (transcriber, engine, _) = makeTranscriber()
        try transcriber.start()
        addTeardownBlock { transcriber.stop() }

        let note = Notification(
            name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
            ])
        NotificationCenter.default.post(note)
        XCTAssertEqual(engine.installTapCount, 2)
    }

    // MARK: - Availability

    func testUnavailabilityReflectsTheOverride() {
        SpeechPermissionCheck.testOverride = .unavailable(.permissionNotRequested)
        let engine = FakeSpeechAudioEngine(format: format)
        let maker = FakeSpeechRecognitionSessionMaker()
        let transcriber = SFSpeechTranscriber(engine: engine, sessionMaker: maker)
        XCTAssertEqual(transcriber.unavailabilityReason, .permissionNotRequested)
        XCTAssertFalse(transcriber.isAvailable)

        SpeechPermissionCheck.testOverride = .available
        XCTAssertTrue(transcriber.isAvailable)
    }

    func testStartThrowsTheReportedUnavailabilityReason() {
        SpeechPermissionCheck.testOverride = .unavailable(.microphoneDenied)
        let engine = FakeSpeechAudioEngine(format: format)
        let maker = FakeSpeechRecognitionSessionMaker()
        let transcriber = SFSpeechTranscriber(engine: engine, sessionMaker: maker)
        XCTAssertThrowsError(try transcriber.start()) { error in
            XCTAssertEqual(
                error as? SpeechTranscribingError, .unavailable(.microphoneDenied))
        }
    }
}

private final class RecordingDelegate: SpeechTranscribingDelegate {
    private(set) var onsets = 0
    private(set) var utterances: [String] = []
    func speechDidDetectOnset() { onsets += 1 }
    func speechDidFinishUtterance(_ text: String) { utterances.append(text) }
}

//
//  EnergyVADTests.swift
//  LunaTests
//
//  The pure RMS-over-frames core, driven with synthetic [Float] frames and
//  an explicit clock — no audio session, no AVAudioEngine.
//

import XCTest
@testable import LunaWriterVoice

final class EnergyVADTests: XCTestCase {

    private let configuration = EnergyVADConfiguration(
        frameDuration: 0.03, thresholdDecibels: -38,
        preRollDuration: 0.25, hangoverDuration: 0.4, minimumSpeechDuration: 0.25)

    /// `count` samples of full-scale noise-free tone, comfortably above -38dBFS.
    private func loudFrame(count: Int = 480) -> [Float] {
        [Float](repeating: 0.5, count: count)
    }

    /// Digital silence, comfortably below -38dBFS.
    private func silentFrame(count: Int = 480) -> [Float] {
        [Float](repeating: 0, count: count)
    }

    func testSilenceEmitsNoEvents() {
        let vad = EnergyVAD(configuration: configuration)
        var time = Date()
        for _ in 0..<20 {
            XCTAssertTrue(vad.ingest(silentFrame(), at: time).isEmpty)
            time = time.addingTimeInterval(configuration.frameDuration)
        }
    }

    func testDecibelsOrdersLoudAboveSilent() {
        XCTAssertGreaterThan(
            EnergyVAD.decibels(ofRMS: loudFrame()),
            EnergyVAD.decibels(ofRMS: silentFrame()))
        XCTAssertEqual(EnergyVAD.decibels(ofRMS: silentFrame()), -.infinity)
    }

    /// A burst long enough to clear `minimumSpeechDuration`, followed by
    /// enough silence to clear `hangoverDuration`, should yield exactly one
    /// onset/end pair.
    func testBurstOfSpeechEmitsOnsetThenEnd() {
        let vad = EnergyVAD(configuration: configuration)
        var time = Date()
        var events: [VoiceActivityEvent] = []

        // 300ms of speech — over the 250ms minimum.
        for _ in 0..<10 {
            events += vad.ingest(loudFrame(), at: time)
            time = time.addingTimeInterval(configuration.frameDuration)
        }
        XCTAssertEqual(events, [.onset], "onset should fire on the very first loud frame")

        // 450ms of silence — over the 400ms hangover.
        for _ in 0..<15 {
            events += vad.ingest(silentFrame(), at: time)
            time = time.addingTimeInterval(configuration.frameDuration)
        }
        XCTAssertEqual(events, [.onset, .end])
    }

    /// A gap in speech shorter than the hangover must not fragment the run
    /// into two segments, and must not reset the speech-start time used for
    /// the minimum-speech check.
    func testShortGapWithinHangoverDoesNotEndTheRun() {
        let vad = EnergyVAD(configuration: configuration)
        var time = Date()
        var events: [VoiceActivityEvent] = []

        events += vad.ingest(loudFrame(), at: time) // onset
        time = time.addingTimeInterval(configuration.frameDuration)

        // 120ms of silence: well under the 400ms hangover.
        for _ in 0..<4 {
            events += vad.ingest(silentFrame(), at: time)
            time = time.addingTimeInterval(configuration.frameDuration)
        }
        XCTAssertEqual(events, [.onset], "a brief dip must not end the run")

        // Speech resumes; no second onset should fire for the same run.
        for _ in 0..<8 {
            events += vad.ingest(loudFrame(), at: time)
            time = time.addingTimeInterval(configuration.frameDuration)
        }
        XCTAssertEqual(events, [.onset], "resuming speech must not re-trigger onset")

        // Now end it for real.
        for _ in 0..<15 {
            events += vad.ingest(silentFrame(), at: time)
            time = time.addingTimeInterval(configuration.frameDuration)
        }
        XCTAssertEqual(events, [.onset, .end])
    }

    /// A speech run shorter than `minimumSpeechDuration` never reaches `.end`
    /// — its `.onset` still fires (early, before the run's true length is
    /// known), but the run is discarded as noise once the hangover elapses.
    func testTooShortSpeechIsRejectedAtEnd() {
        let vad = EnergyVAD(configuration: configuration)
        var time = Date()
        var events: [VoiceActivityEvent] = []

        // 90ms of speech — under the 250ms minimum.
        for _ in 0..<3 {
            events += vad.ingest(loudFrame(), at: time)
            time = time.addingTimeInterval(configuration.frameDuration)
        }
        XCTAssertEqual(events, [.onset])

        // 450ms of silence — clears the hangover, closing the run.
        for _ in 0..<15 {
            events += vad.ingest(silentFrame(), at: time)
            time = time.addingTimeInterval(configuration.frameDuration)
        }
        XCTAssertEqual(events, [.onset], "too-short speech should never reach .end")
    }

    /// After a rejected short run, a later real speech burst must behave
    /// normally — the state machine has to have reset, not latched.
    func testStateResetsAfterARejectedRun() {
        let vad = EnergyVAD(configuration: configuration)
        var time = Date()

        for _ in 0..<3 { // too short, gets rejected
            _ = vad.ingest(loudFrame(), at: time)
            time = time.addingTimeInterval(configuration.frameDuration)
        }
        for _ in 0..<15 { // clears the hangover
            _ = vad.ingest(silentFrame(), at: time)
            time = time.addingTimeInterval(configuration.frameDuration)
        }

        var events: [VoiceActivityEvent] = []
        for _ in 0..<10 { // a proper burst
            events += vad.ingest(loudFrame(), at: time)
            time = time.addingTimeInterval(configuration.frameDuration)
        }
        for _ in 0..<15 {
            events += vad.ingest(silentFrame(), at: time)
            time = time.addingTimeInterval(configuration.frameDuration)
        }
        XCTAssertEqual(events, [.onset, .end])
    }

    func testPreRollFrameCountRoundsUpToCoverTheConfiguredDuration() {
        // 250ms / 30ms = 8.33 frames; rounding down would drop part of the
        // word that triggered the onset.
        XCTAssertEqual(configuration.preRollFrameCount, 9)
        let tighter = EnergyVADConfiguration(frameDuration: 0.025, preRollDuration: 0.25)
        XCTAssertEqual(tighter.preRollFrameCount, 10)
    }

    func testResetDiscardsAnInProgressRunWithoutEmittingEnd() {
        let vad = EnergyVAD(configuration: configuration)
        var time = Date()
        XCTAssertEqual(vad.ingest(loudFrame(), at: time), [.onset])
        vad.reset()

        var events: [VoiceActivityEvent] = []
        for _ in 0..<15 {
            time = time.addingTimeInterval(configuration.frameDuration)
            events += vad.ingest(silentFrame(), at: time)
        }
        XCTAssertTrue(events.isEmpty, "no .end should follow a reset run")
    }
}

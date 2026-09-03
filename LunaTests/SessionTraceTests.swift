//
//  SessionTraceTests.swift
//  LunaTests
//

import CoreGraphics
import Foundation
import XCTest
@testable import LunaGaze
@testable import LunaWriterReadAlong

final class SessionTraceTests: XCTestCase {

    private func state(sentence: Int?) -> ReadingState {
        ReadingState(
            activeSentence: sentence, readUpToWord: 2, cursorWord: 3,
            mode: .gaze, quality: 0.7, residual: 12)
    }

    func testFramesAreKeptAtTenHertzRatherThanAtCameraRate() {
        let trace = SessionTrace()
        var kept = 0
        for frame in 0..<600 {
            let time = Double(frame) / 60
            if trace.record(at: time, gaze: .zero, gate: .ok, state: state(sentence: 0)) {
                kept += 1
            }
        }
        XCTAssertEqual(kept, trace.count)
        XCTAssertLessThan(kept, 600 / 4, "ten seconds of camera frames must not all be kept")

        let times = trace.samples.map(\.time)
        for (earlier, later) in zip(times, times.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                later - earlier, trace.minimumInterval,
                "two kept frames must be at least one decimation interval apart")
        }
        XCTAssertGreaterThan(
            times.last ?? 0, 9.0, "decimation must not stop recording early")
    }

    func testTheOldestFramesFallOffOnceTheBufferIsFull() {
        let trace = SessionTrace(capacity: 5, minimumInterval: 0)
        for frame in 0..<9 {
            trace.record(
                at: Double(frame), gaze: nil, gate: .ok, state: state(sentence: frame))
        }
        XCTAssertEqual(trace.count, 5)
        XCTAssertEqual(trace.samples.map(\.sentence), [4, 5, 6, 7, 8])
        XCTAssertEqual(trace.samples.map(\.time), [4, 5, 6, 7, 8])
    }

    func testAFrameCarriesWhatTheModelBelievedWhenItArrived() {
        let trace = SessionTrace(minimumInterval: 0)
        trace.record(
            at: 3, gaze: CGPoint(x: 40, y: 90), gate: .blink, state: state(sentence: 7))

        let sample = trace.samples.first
        XCTAssertEqual(sample?.gazeX, 40)
        XCTAssertEqual(sample?.gazeY, 90)
        XCTAssertEqual(sample?.gate, "blink")
        XCTAssertEqual(sample?.mode, "gaze")
        XCTAssertEqual(sample?.sentence, 7)
        XCTAssertEqual(sample?.cursorWord, 3)
        XCTAssertEqual(sample?.residual, 12)
    }

    func testAFrameWithNoGazeRecordsThatRatherThanAPointOfZero() {
        let trace = SessionTrace(minimumInterval: 0)
        trace.record(at: 0, gaze: nil, gate: .away, state: state(sentence: nil))
        XCTAssertNil(trace.samples.first?.gazeX)
        XCTAssertNil(trace.samples.first?.sentence)
    }

    func testTheExportIsJSONThatReadsBackAsTheSameFrames() throws {
        let trace = SessionTrace(minimumInterval: 0)
        for frame in 0..<4 {
            trace.record(
                at: Double(frame), gaze: CGPoint(x: 1, y: 2), gate: .ok,
                state: state(sentence: frame))
        }
        let data = try trace.jsonData()
        let decoded = try JSONDecoder().decode([SessionTraceSample].self, from: data)
        XCTAssertEqual(decoded, trace.samples)
    }

    func testResettingEmptiesTheBufferAndTheDecimationClock() {
        let trace = SessionTrace()
        trace.record(at: 0, gaze: nil, gate: .ok, state: state(sentence: 0))
        trace.reset()
        XCTAssertEqual(trace.count, 0)
        XCTAssertTrue(trace.record(at: 0.01, gaze: nil, gate: .ok, state: state(sentence: 0)))
    }
}

//
//  UtteranceSegmenterTests.swift
//  LunaWriterTests
//
//  The segmenter owns no timer, so every test drives it with an injected
//  clock instead of sleeping — see UtteranceSegmenter's `now:` seam.
//

import XCTest
@testable import LunaWriterVoice

final class UtteranceSegmenterTests: XCTestCase {

    private var clock = Date(timeIntervalSince1970: 0)

    private func makeSegmenter() -> UtteranceSegmenter {
        UtteranceSegmenter(now: { [self] in clock })
    }

    private func advance(_ seconds: TimeInterval) {
        clock = clock.addingTimeInterval(seconds)
    }

    func testFinalResultClosesImmediately() {
        let segmenter = makeSegmenter()
        XCTAssertNil(segmenter.receivePartial("hi"))
        advance(0.05)
        let utterance = segmenter.receiveFinal("hi there")
        XCTAssertEqual(utterance.text, "hi there")
        XCTAssertNil(segmenter.tick(), "nothing should be pending after a final result")
    }

    func testSilenceBoundaryClosesAfter400Milliseconds() {
        let segmenter = makeSegmenter()
        segmenter.receivePartial("hi")
        XCTAssertNil(segmenter.tick(), "under the timeout, nothing should close yet")

        advance(0.39)
        XCTAssertNil(segmenter.tick(), "just under 400ms should still be pending")

        advance(0.02)
        let utterance = segmenter.tick()
        XCTAssertEqual(utterance?.text, "hi")
    }

    func testPartialReplacesRatherThanConcatenates() {
        let segmenter = makeSegmenter()
        segmenter.receivePartial("hi")
        advance(0.1)
        segmenter.receivePartial("hi there")
        advance(0.1)
        segmenter.receivePartial("hi there friend")

        advance(0.5)
        let utterance = segmenter.tick()
        XCTAssertEqual(utterance?.text, "hi there friend")
    }

    func testTwentySecondCapFlushesEvenWithoutSilence() {
        let segmenter = makeSegmenter()
        var flushes: [Utterance] = []
        // Keep feeding partials well under the 400ms timeout so silence never
        // triggers, but push the total run past the 20s cap.
        for step in 0..<80 {
            if let flushed = segmenter.receivePartial("word \(step)") { flushes.append(flushed) }
            advance(0.3)
            if let flushed = segmenter.tick() { flushes.append(flushed) }
        }
        let capped = try? XCTUnwrap(flushes.first)
        XCTAssertNotNil(capped, "the 20s cap should have forced a flush")
        XCTAssertLessThanOrEqual(
            capped?.endedAt.timeIntervalSince(capped?.startedAt ?? .distantPast) ?? 0,
            20.3, "a capped utterance should not run meaningfully past the cap")
        XCTAssertGreaterThanOrEqual(
            capped?.endedAt.timeIntervalSince(capped?.startedAt ?? .distantPast) ?? 0,
            20.0, "the cap should not fire early")
    }

    func testResetDiscardsPendingTextWithoutEmitting() {
        let segmenter = makeSegmenter()
        segmenter.receivePartial("hi")
        segmenter.reset()
        advance(1)
        XCTAssertNil(segmenter.tick())
    }
}

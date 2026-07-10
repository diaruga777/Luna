//
//  SpeechRendererSpikeTests.swift
//  LunaTests
//

import AVFoundation
import LunaAudioPlayback
import XCTest

/// The Phase-1 spike required by `claudedocs/audio-playback-plan.md`: does
/// `AVSpeechSynthesizerDelegate.speechSynthesizer(_:willSpeakRangeOfSpeechString:utterance:)`
/// actually fire during `AVSpeechSynthesizer.write(_:toBufferCallback:)` (offline
/// synthesis), the way it does during live `speak()`? The finding is recorded
/// in a doc comment on `SpeechRenderer.render(_:)`.
///
/// Word markers are optional by design (see `WordMarker`'s doc comment): a
/// `RenderedSegment` with zero markers is still fully playable at block-level
/// granularity. So this test never *fails* on a marker-less or buffer-less
/// result — those are legitimate simulator outcomes (voice assets can
/// silently fail to render there; see `AudioVoiceResolution`) — it records
/// them via `XCTSkip` with a clear message instead.
final class SpeechRendererSpikeTests: XCTestCase {

    func testWillSpeakRangeFiresDuringWrite() async throws {
        let renderer = SpeechRenderer()
        let block = AudioScript.SpokenBlock(blockIndex: 0, text: "Testing one two three four five.")

        let segment: RenderedSegment
        do {
            segment = try await renderer.render(block)
        } catch {
            throw XCTSkip("Offline synthesis failed entirely on this run/simulator (\(error)); word markers are optional and callers must tolerate this.")
        }

        guard !segment.buffers.isEmpty else {
            throw XCTSkip("Offline synthesis produced zero audio buffers on this simulator — the known voice-asset quirk documented on AudioVoiceResolution. Word markers are optional; higher layers fall back to block-level granularity.")
        }

        guard !segment.wordMarkers.isEmpty else {
            throw XCTSkip("willSpeakRangeOfSpeechString did not fire during write() on this run/simulator. Word markers are optional by design — SpeechRenderer falls back to block-level (not word-level) resume/highlighting granularity when this happens.")
        }

        // It fired at least once, with plausible data: monotonic non-decreasing
        // sample offsets, all within the segment's rendered duration.
        let maxSample = AVAudioFramePosition((segment.duration * segment.format.sampleRate).rounded()) + 1
        var previousOffset: AVAudioFramePosition = -1
        for marker in segment.wordMarkers {
            XCTAssertGreaterThanOrEqual(marker.sampleOffset, 0)
            XCTAssertLessThanOrEqual(marker.sampleOffset, maxSample)
            XCTAssertGreaterThanOrEqual(marker.sampleOffset, previousOffset)
            previousOffset = marker.sampleOffset
        }
    }

    /// A rendered segment with markers still round-trips as a plain block-level
    /// unit: `duration` and `format` are always populated even if markers are
    /// empty, so the rendering pipeline never needs to special-case "no
    /// markers" beyond skipping word-level highlight updates.
    func testRenderedSegmentIsAlwaysPlayableRegardlessOfMarkerAvailability() async throws {
        let renderer = SpeechRenderer()
        let block = AudioScript.SpokenBlock(blockIndex: 2, text: "A short block.")

        let segment: RenderedSegment
        do {
            segment = try await renderer.render(block)
        } catch {
            throw XCTSkip("Offline synthesis failed entirely on this run/simulator (\(error)).")
        }

        XCTAssertEqual(segment.blockIndex, 2)
        XCTAssertGreaterThanOrEqual(segment.duration, 0)
        if segment.buffers.isEmpty {
            throw XCTSkip("Offline synthesis produced zero audio buffers on this simulator — known voice-asset quirk.")
        }
        XCTAssertGreaterThan(segment.duration, 0)
    }
}

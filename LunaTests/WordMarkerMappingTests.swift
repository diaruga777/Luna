//
//  WordMarkerMappingTests.swift
//  LunaTests
//

import AVFoundation
@testable import LunaAudioPlayback
import XCTest

/// `SpeechRenderer.makeWordMarkers(from:sampleRateRatio:)` rescales captured
/// (character range, native-sample-offset) pairs into the canonical sample
/// rate space. These tests feed it synthetic callback sequences — no real
/// synthesis — and check the resulting offsets are monotonic and within
/// bounds, per the plan's word-marker mapping requirement.
final class WordMarkerMappingTests: XCTestCase {

    func testOffsetsPassThroughUnchangedAtUnityRatio() {
        let ranges: [(range: NSRange, nativeFrameOffset: AVAudioFramePosition)] = [
            (NSRange(location: 0, length: 3), 0),
            (NSRange(location: 4, length: 5), 1000),
            (NSRange(location: 10, length: 4), 2500),
        ]

        let markers = SpeechRenderer.makeWordMarkers(from: ranges, sampleRateRatio: 1.0)

        XCTAssertEqual(markers.map(\.sampleOffset), [0, 1000, 2500])
        XCTAssertEqual(markers.map(\.utteranceRange), ranges.map(\.range))
    }

    func testOffsetsScaleBySampleRateRatio() {
        // e.g. native 22050 Hz -> canonical 44100 Hz: ratio 2.0.
        let ranges: [(range: NSRange, nativeFrameOffset: AVAudioFramePosition)] = [
            (NSRange(location: 0, length: 2), 0),
            (NSRange(location: 3, length: 2), 500),
            (NSRange(location: 6, length: 3), 1100),
        ]

        let markers = SpeechRenderer.makeWordMarkers(from: ranges, sampleRateRatio: 2.0)

        XCTAssertEqual(markers.map(\.sampleOffset), [0, 1000, 2200])
    }

    func testOffsetsRemainMonotonicNonDecreasingAfterScaling() {
        // Synthetic increasing sequence of callback offsets, as would occur
        // during a real render (words are spoken in order).
        let nativeOffsets: [AVAudioFramePosition] = [0, 120, 340, 900, 901, 1500]
        let ranges = nativeOffsets.enumerated().map { index, offset in
            (range: NSRange(location: index * 5, length: 4), nativeFrameOffset: offset)
        }

        let markers = SpeechRenderer.makeWordMarkers(from: ranges, sampleRateRatio: 1.333)

        let offsets = markers.map(\.sampleOffset)
        for (previous, next) in zip(offsets, offsets.dropFirst()) {
            XCTAssertLessThanOrEqual(previous, next, "scaled offsets must stay monotonic non-decreasing")
        }
    }

    func testOffsetsStayWithinBoundsOfScaledTotalDuration() {
        let totalNativeFrames: AVAudioFramePosition = 44100 // 1s @ 44100Hz native
        let ratio = 0.5 // e.g. downsampling to 22050Hz canonical
        let ranges: [(range: NSRange, nativeFrameOffset: AVAudioFramePosition)] = [
            (NSRange(location: 0, length: 1), 0),
            (NSRange(location: 2, length: 1), 22050),
            (NSRange(location: 4, length: 1), totalNativeFrames - 1),
        ]

        let markers = SpeechRenderer.makeWordMarkers(from: ranges, sampleRateRatio: ratio)

        let scaledTotal = AVAudioFramePosition((Double(totalNativeFrames) * ratio).rounded())
        for marker in markers {
            XCTAssertGreaterThanOrEqual(marker.sampleOffset, 0)
            XCTAssertLessThanOrEqual(marker.sampleOffset, scaledTotal)
        }
    }

    func testEmptyRangesProduceEmptyMarkers() {
        let markers = SpeechRenderer.makeWordMarkers(from: [], sampleRateRatio: 1.5)
        XCTAssertTrue(markers.isEmpty)
    }

    func testPreservesCountAndOrder() {
        let ranges: [(range: NSRange, nativeFrameOffset: AVAudioFramePosition)] = (0..<10).map {
            (range: NSRange(location: $0 * 3, length: 2), nativeFrameOffset: AVAudioFramePosition($0 * 100))
        }
        let markers = SpeechRenderer.makeWordMarkers(from: ranges, sampleRateRatio: 1.0)
        XCTAssertEqual(markers.count, ranges.count)
        for (marker, expected) in zip(markers, ranges) {
            XCTAssertEqual(marker.utteranceRange, expected.range)
        }
    }
}

//
//  AudioFormatConversionTests.swift
//  LunaTests
//

import AVFoundation
@testable import LunaAudioPlayback
import XCTest

/// `AudioFormatConversion.convert` is the shared `AVAudioConverter` plumbing
/// both `SpeechRenderer` (native synthesizer format -> canonical float32) and
/// `ToneLibrary` (bundled .caf -> canonical) go through. These tests feed it
/// hand-built synthetic buffers (no real synthesis or file I/O) and check the
/// output format/sample counts are sane.
final class AudioFormatConversionTests: XCTestCase {

    /// Builds an int16-interleaved mono buffer of `frameCount` frames at
    /// `sampleRate`, filled with a simple ramp so non-silence is easy to
    /// assert on if ever needed.
    private func makeInt16Buffer(frameCount: AVAudioFrameCount, sampleRate: Double) -> (AVAudioPCMBuffer, AVAudioFormat) {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let channel = buffer.int16ChannelData![0]
        for i in 0..<Int(frameCount) {
            channel[i] = Int16(truncatingIfNeeded: i * 37)
        }
        return (buffer, format)
    }

    func testConvertingToMatchingFormatIsANoOp() throws {
        let (buffer, format) = makeInt16Buffer(frameCount: 512, sampleRate: 22050)
        let result = try AudioFormatConversion.convert([buffer], from: format, to: format)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0] === buffer)
    }

    func testConvertingInt16InterleavedToCanonicalFloat32Deinterleaved() throws {
        let (buffer, sourceFormat) = makeInt16Buffer(frameCount: 1000, sampleRate: 22050)
        let canonical = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 22050, channels: 1, interleaved: false)!

        let result = try AudioFormatConversion.convert([buffer], from: sourceFormat, to: canonical)

        XCTAssertEqual(result.count, 1)
        let out = result[0]
        XCTAssertEqual(out.format.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(out.format.isInterleaved)
        XCTAssertEqual(out.format.sampleRate, 22050)
        // Same sample rate in/out -> frame count should be very close (allow
        // a small margin for converter buffering behavior).
        XCTAssertEqual(Double(out.frameLength), 1000, accuracy: 8)
    }

    func testConvertingAcrossSampleRatesScalesFrameCountByRatio() throws {
        let (buffer, sourceFormat) = makeInt16Buffer(frameCount: 22050, sampleRate: 22050)
        let canonical = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!

        let result = try AudioFormatConversion.convert([buffer], from: sourceFormat, to: canonical)

        XCTAssertEqual(result.count, 1)
        // 1 second of audio at 22050 Hz in -> ~1 second at 44100 Hz out -> ~44100 frames.
        XCTAssertEqual(Double(result[0].frameLength), 44100, accuracy: 200)
    }

    func testConvertingMultipleBuffersPreservesOrderAndCount() throws {
        let (bufferA, sourceFormat) = makeInt16Buffer(frameCount: 256, sampleRate: 22050)
        let (bufferB, _) = makeInt16Buffer(frameCount: 128, sampleRate: 22050)
        let canonical = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 22050, channels: 1, interleaved: false)!

        let result = try AudioFormatConversion.convert([bufferA, bufferB], from: sourceFormat, to: canonical)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Double(result[0].frameLength), 256, accuracy: 8)
        XCTAssertEqual(Double(result[1].frameLength), 128, accuracy: 8)
    }

    func testEmptyBufferListConvertsToEmptyList() throws {
        let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 22050, channels: 1, interleaved: true)!
        let canonical = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 22050, channels: 1, interleaved: false)!
        let result = try AudioFormatConversion.convert([], from: sourceFormat, to: canonical)
        XCTAssertTrue(result.isEmpty)
    }
}

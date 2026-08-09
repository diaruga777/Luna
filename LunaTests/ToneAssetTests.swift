//
//  ToneAssetTests.swift
//  LunaTests
//

import AVFoundation
import LunaAudioPlayback
import XCTest

/// The two bundled chime assets (`scripts/make_tones.py`) load and decode to
/// non-empty PCM buffers of their expected approximate durations, both in
/// their native on-disk format and after conversion to an arbitrary target
/// format (exercising the same conversion path `ArticleAudioEngine` uses to
/// match a `SpeechRenderer`'s canonical format).
final class ToneAssetTests: XCTestCase {

    func testTransitionChimeDecodesToNonEmptyBufferOfExpectedDuration() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = try ToneLibrary.loadBuffer(.transition, format: format)
        XCTAssertGreaterThan(buffer.frameLength, 0)
        let duration = Double(buffer.frameLength) / format.sampleRate
        XCTAssertEqual(duration, 0.79, accuracy: 0.1)
    }

    func testFinalChimeDecodesToNonEmptyBufferOfExpectedDuration() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = try ToneLibrary.loadBuffer(.final, format: format)
        XCTAssertGreaterThan(buffer.frameLength, 0)
        let duration = Double(buffer.frameLength) / format.sampleRate
        XCTAssertEqual(duration, 1.55, accuracy: 0.15)
    }

    /// Loading at a different target sample rate/format exercises the
    /// AVAudioConverter path (not just a passthrough when formats already
    /// match) and must still produce sane, non-empty, roughly-correct-duration
    /// audio.
    func testToneConvertsToNonNativeCanonicalFormat() throws {
        guard let canonical = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 22050, channels: 1, interleaved: false
        ) else {
            return XCTFail("could not construct canonical format")
        }
        let buffer = try ToneLibrary.loadBuffer(.transition, format: canonical)
        XCTAssertEqual(buffer.format, canonical)
        XCTAssertGreaterThan(buffer.frameLength, 0)
        let duration = Double(buffer.frameLength) / canonical.sampleRate
        XCTAssertEqual(duration, 0.79, accuracy: 0.15)
    }
}

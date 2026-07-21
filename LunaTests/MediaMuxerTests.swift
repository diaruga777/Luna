//
//  MediaMuxerTests.swift
//  LunaTests
//
//  MediaMuxer combines Reddit's separate video-only/audio-only DASH files into
//  one playable asset. These tests generate tiny real video/audio files
//  in-process (AVAssetWriter / AVAudioFile) rather than bundling fixtures, so
//  the real AVFoundation composition/export path runs end to end.
//

import AVFoundation
import XCTest
@testable import LunaMediaDownload

final class MediaMuxerTests: XCTestCase {

    private var scratchDirectory: URL!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaMuxerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratchDirectory)
        super.tearDown()
    }

    private func freshURL(ext: String) -> URL {
        scratchDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
    }

    /// Writes a tiny, real H.264 mp4 with only a video track, `duration` seconds
    /// of solid-color frames at `fps`.
    private func makeVideoFile(
        duration: Double = 0.6, fps: Int32 = 10, size: CGSize = CGSize(width: 32, height: 32)
    ) throws -> URL {
        let url = freshURL(ext: "mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let bufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: bufferAttributes)
        guard writer.canAdd(input) else {
            throw NSError(domain: "MediaMuxerTests", code: 1)
        }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frameCount = max(1, Int(duration * Double(fps)))
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var pixelBufferOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
            guard let pixelBuffer = pixelBufferOut else { continue }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
                memset(base, frame.isMultiple(of: 2) ? 0xFF : 0x00, rowBytes * Int(size.height))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: fps))
        }
        input.markAsFinished()
        let done = expectation(description: "video writer finished")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 10)
        return url
    }

    /// Writes a tiny, real AAC m4a with `duration` seconds of silence.
    private func makeAudioFile(duration: Double = 0.3, sampleRate: Double = 44_100) throws -> URL {
        let url = freshURL(ext: "m4a")
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw NSError(domain: "MediaMuxerTests", code: 2)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "MediaMuxerTests", code: 3)
        }
        buffer.frameLength = frameCount // silence — the buffer is zero-filled on creation
        try file.write(from: buffer)
        return url
    }

    private func seconds(_ time: CMTime) -> Double { CMTimeGetSeconds(time) }

    // MARK: - Video + audio mux

    func testMuxesVideoAndAudioIntoOnePlayableFile() async throws {
        let video = try makeVideoFile(duration: 0.6)
        let audio = try makeAudioFile(duration: 0.6)
        let output = freshURL(ext: "mp4")

        try await MediaMuxer.mux(videoURL: video, audioURL: audio, outputURL: output)

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let asset = AVURLAsset(url: output)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)
    }

    func testAudioShorterThanVideoIsTrimmedToTheShorterDuration() async throws {
        let video = try makeVideoFile(duration: 0.8)
        let audio = try makeAudioFile(duration: 0.3) // shorter than the video
        let output = freshURL(ext: "mp4")

        try await MediaMuxer.mux(videoURL: video, audioURL: audio, outputURL: output)

        let asset = AVURLAsset(url: output)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            return XCTFail("expected an audio track in the muxed output")
        }
        let audioDuration = seconds(try await audioTrack.load(.timeRange).duration)
        XCTAssertEqual(audioDuration, 0.3, accuracy: 0.15,
                       "the audio track must not extend past its own (shorter) source duration")

        let videoDuration = seconds(try await asset.load(.duration))
        XCTAssertEqual(videoDuration, 0.8, accuracy: 0.15,
                       "the overall asset duration follows the (longer) video track")
    }

    // MARK: - Video-only passthrough (no usable audio track)

    func testNoAudioTrackInSourceStillProducesAPlayableVideoOnlyFile() async throws {
        let video = try makeVideoFile(duration: 0.5)
        // A video file has no audio track of its own — used here as a stand-in for
        // Reddit's video-only DASH leg with a missing/unavailable audio URL.
        let output = freshURL(ext: "mp4")

        try await MediaMuxer.mux(videoURL: video, audioURL: video, outputURL: output)

        let asset = AVURLAsset(url: output)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertTrue(audioTracks.isEmpty, "no audio track exists to mux in, so none is produced")
    }

    // MARK: - Failure path

    func testNoVideoTrackInSourceThrowsNoVideoTrack() async throws {
        // An audio-only file has no video track at all.
        let audio = try makeAudioFile(duration: 0.2)
        let output = freshURL(ext: "mp4")

        do {
            try await MediaMuxer.mux(videoURL: audio, audioURL: audio, outputURL: output)
            XCTFail("expected MediaMuxer.MuxError.noVideoTrack")
        } catch MediaMuxer.MuxError.noVideoTrack {
            // expected
        }
    }

    // Note: `.exportSessionUnavailable` (AVAssetExportSession init returning nil
    // for both the passthrough and highest-quality presets) has no reachable
    // trigger from valid composition inputs and no injection seam in
    // `MediaMuxer` — not exercised here.
}

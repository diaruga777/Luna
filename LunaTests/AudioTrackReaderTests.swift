//
//  AudioTrackReaderTests.swift
//  LunaTests
//

import AVFoundation
import LunaMediaDownload
import LunaTranscribe
import XCTest

/// Decoding real containers written at test time: an AAC m4a, a video-only
/// mp4, and the two muxed together.
final class AudioTrackReaderTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioTrackReaderTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testAnAudioFileDecodesToTheRequestedFormatForItsWholeDuration() async throws {
        let url = try makeAudioFile(duration: 0.5)

        let decoded = try await AudioTrackReader.open(fileURL: url)
        var frames: AVAudioFrameCount = 0
        var firstStart: CMTime?
        for try await chunk in decoded.chunks {
            XCTAssertEqual(chunk.buffer.format, decoded.format)
            frames += chunk.buffer.frameLength
            if firstStart == nil { firstStart = chunk.start }
        }

        XCTAssertEqual(decoded.format.sampleRate, 16_000)
        XCTAssertEqual(decoded.format.channelCount, 1)
        XCTAssertFalse(decoded.format.isInterleaved)
        XCTAssertEqual(decoded.duration, 0.5, accuracy: 0.1)
        // AAC pads its first frames, so a few hundred frames of slack.
        XCTAssertEqual(Double(frames), 0.5 * 16_000, accuracy: 0.15 * 16_000)
        XCTAssertEqual(firstStart?.seconds ?? -1, 0, accuracy: 0.1)
    }

    func testARequestedFormatIsHonoured() async throws {
        let url = try makeAudioFile(duration: 0.3)
        let wanted = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: true)!

        let decoded = try await AudioTrackReader.open(fileURL: url, outputFormat: wanted)
        var frames: AVAudioFrameCount = 0
        for try await chunk in decoded.chunks {
            XCTAssertEqual(chunk.buffer.format, wanted)
            frames += chunk.buffer.frameLength
        }
        XCTAssertEqual(Double(frames), 0.3 * 44_100, accuracy: 0.15 * 44_100)
    }

    func testAVideoWithSoundYieldsItsAudioTrack() async throws {
        let video = try makeVideoFile(duration: 0.6)
        let audio = try makeAudioFile(duration: 0.6)
        let muxed = directory.appendingPathComponent("muxed.mp4")
        try await MediaMuxer.mux(videoURL: video, audioURL: audio, outputURL: muxed)

        let decoded = try await AudioTrackReader.open(fileURL: muxed)
        var frames: AVAudioFrameCount = 0
        for try await chunk in decoded.chunks { frames += chunk.buffer.frameLength }

        XCTAssertGreaterThan(frames, 0)
        XCTAssertEqual(Double(frames), 0.6 * 16_000, accuracy: 0.2 * 16_000)
    }

    func testAVideoWithoutSoundHasNoAudioTrack() async throws {
        let video = try makeVideoFile(duration: 0.3)
        do {
            _ = try await AudioTrackReader.open(fileURL: video)
            XCTFail("a silent video has nothing to transcribe")
        } catch let error as TranscriptionError {
            XCTAssertEqual(error, .noAudioTrack)
        }
    }

    func testAFileThatIsNotMediaFailsToDecode() async throws {
        let junk = directory.appendingPathComponent("junk.mp4")
        try Data("not a movie".utf8).write(to: junk)
        do {
            _ = try await AudioTrackReader.open(fileURL: junk)
            XCTFail("junk is not decodable")
        } catch let error as TranscriptionError {
            switch error {
            case .decodingFailed, .noAudioTrack: break
            default: XCTFail("unexpected \(error)")
            }
        }
    }

    // MARK: - Files written at test time

    private func makeAudioFile(duration: Double, sampleRate: Double = 44_100) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).m4a")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        // A 440 Hz tone, so the track carries signal rather than digital silence.
        if let samples = buffer.floatChannelData?[0] {
            for frame in 0..<Int(frameCount) {
                samples[frame] = Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate)) * 0.3
            }
        }
        try file.write(from: buffer)
        return url
    }

    private func makeVideoFile(duration: Double, fps: Int32 = 10) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).mp4")
        let size = CGSize(width: 32, height: 32)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ])
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<max(1, Int(duration * Double(fps))) {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let pixelBuffer else { continue }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                memset(base, frame.isMultiple(of: 2) ? 0xFF : 0x00,
                       CVPixelBufferGetBytesPerRow(pixelBuffer) * Int(size.height))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: fps))
        }
        input.markAsFinished()
        let done = expectation(description: "video written")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 10)
        return url
    }
}

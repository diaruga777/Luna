//
//  AudioTrackReader.swift
//  LunaTranscribe
//

import AVFoundation
import Foundation

/// Decodes the first audio track of a local media file into PCM buffers.
///
/// The container may be audio-only or a video; only the audio track is read,
/// so a video is never decoded. The reader asks AVFoundation for interleaved
/// float PCM at the requested rate and channel count, then converts to the
/// requested layout when it differs, because asset readers do not produce
/// deinterleaved output.
public enum AudioTrackReader {

    /// One decoded run of samples and where it starts in the file.
    public struct Chunk: @unchecked Sendable {
        public let buffer: AVAudioPCMBuffer
        public let start: CMTime
    }

    public struct Decoded {
        /// The format every chunk's buffer carries.
        public let format: AVAudioFormat
        public let duration: TimeInterval
        public let chunks: AsyncThrowingStream<Chunk, Error>
    }

    /// The format used when a caller asks for none: mono float at 16 kHz, the
    /// rate speech recognizers consume.
    public static var defaultFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    }

    /// Opens `fileURL` and starts decoding its first audio track.
    ///
    /// Throws `TranscriptionError.noAudioTrack` for a file with no audio track,
    /// and `.decodingFailed` for a file AVFoundation cannot read. Decode errors
    /// after the first chunk arrive through the stream.
    public static func open(
        fileURL: URL, outputFormat requested: AVAudioFormat? = nil
    ) async throws -> Decoded {
        let target = requested ?? defaultFormat
        let asset = AVURLAsset(url: fileURL)
        let tracks: [AVAssetTrack]
        let duration: CMTime
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
            duration = try await asset.load(.duration)
        } catch {
            throw TranscriptionError.decodingFailed(error.localizedDescription)
        }
        guard let track = tracks.first else { throw TranscriptionError.noAudioTrack }

        guard let readerFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: target.sampleRate,
            channels: target.channelCount, interleaved: true)
        else { throw TranscriptionError.decodingFailed("unsupported output format") }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw TranscriptionError.decodingFailed(error.localizedDescription)
        }
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: [track], audioSettings: readerFormat.settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw TranscriptionError.decodingFailed("cannot add an audio output")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw TranscriptionError.decodingFailed(
                reader.error?.localizedDescription ?? "cannot start reading")
        }

        let converter: AVAudioConverter?
        if readerFormat == target {
            converter = nil
        } else {
            guard let made = AVAudioConverter(from: readerFormat, to: target) else {
                reader.cancelReading()
                throw TranscriptionError.decodingFailed("cannot convert to the requested format")
            }
            converter = made
        }

        let chunks = AsyncThrowingStream<Chunk, Error> { continuation in
            let task = Task.detached(priority: .utility) {
                do {
                    while !Task.isCancelled, let sample = output.copyNextSampleBuffer() {
                        guard let chunk = try Self.chunk(
                            from: sample, readerFormat: readerFormat, target: target,
                            converter: converter)
                        else { continue }
                        continuation.yield(chunk)
                    }
                    if reader.status == .failed {
                        throw TranscriptionError.decodingFailed(
                            reader.error?.localizedDescription ?? "decoding failed")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                reader.cancelReading()
            }
        }
        return Decoded(format: target, duration: duration.seconds, chunks: chunks)
    }

    private static func chunk(
        from sample: CMSampleBuffer, readerFormat: AVAudioFormat, target: AVAudioFormat,
        converter: AVAudioConverter?
    ) throws -> Chunk? {
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0,
              let raw = AVAudioPCMBuffer(pcmFormat: readerFormat, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        raw.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(frames), into: raw.mutableAudioBufferList)
        guard status == noErr else {
            throw TranscriptionError.decodingFailed("PCM copy failed (\(status))")
        }
        let start = CMSampleBufferGetPresentationTimeStamp(sample)
        guard let converter else { return Chunk(buffer: raw, start: start) }
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: raw.frameLength) else {
            return nil
        }
        // Same sample rate on both sides: a frame-for-frame layout change.
        try converter.convert(to: converted, from: raw)
        return Chunk(buffer: converted, start: start)
    }
}

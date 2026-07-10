//
//  AudioFormatConversion.swift
//  LunaAudioPlayback
//

import AVFoundation

/// Shared `AVAudioConverter` plumbing: convert an ordered list of PCM buffers
/// from one format to another, preserving order and per-buffer boundaries.
/// Used by both `SpeechRenderer` (native synthesizer format -> canonical
/// float32) and `ToneLibrary` (bundled .caf's native format -> canonical).
/// Factored out so it's directly unit-testable with synthetic buffers,
/// independent of real speech synthesis or file I/O.
enum AudioFormatConversion {
    enum ConversionError: Error, Equatable {
        case converterCreationFailed
        case outputBufferCreationFailed
    }

    /// Converts every buffer in `buffers` from `source` to `target`. Returns
    /// `buffers` unchanged (no-op) if the formats already match.
    static func convert(
        _ buffers: [AVAudioPCMBuffer], from source: AVAudioFormat, to target: AVAudioFormat
    ) throws -> [AVAudioPCMBuffer] {
        if source == target { return buffers }
        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw ConversionError.converterCreationFailed
        }
        let ratio = target.sampleRate / source.sampleRate
        var result: [AVAudioPCMBuffer] = []
        for buffer in buffers {
            // Each buffer is a complete, finite chunk of audio, not a live
            // stream — reset any resampler state left over from the previous
            // buffer's conversion before starting this one.
            converter.reset()
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 4
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                throw ConversionError.outputBufferCreationFailed
            }
            var conversionError: NSError?
            var delivered = false
            converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
                if delivered {
                    // `.endOfStream`, not `.noDataNow`: this buffer is the
                    // *entire*, complete input — telling the converter "no
                    // more data will ever come" (rather than "try again
                    // later") lets it flush its resampler tail instead of
                    // truncating output early.
                    outStatus.pointee = .endOfStream
                    return nil
                }
                delivered = true
                outStatus.pointee = .haveData
                return buffer
            }
            if let conversionError { throw conversionError }
            result.append(outBuffer)
        }
        return result
    }
}

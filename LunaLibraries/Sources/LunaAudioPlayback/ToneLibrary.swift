//
//  ToneLibrary.swift
//  LunaAudioPlayback
//

import AVFoundation

/// The bundled chime assets (see `scripts/make_tones.py`), decoded once into
/// PCM buffers matching `ArticleAudioEngine`'s canonical format.
public enum ToneAsset: String, CaseIterable, Sendable {
    /// Soft, ~0.8s, two ascending notes — played between segments (e.g. before
    /// an autoplay "Now Reading — <title>" announcement).
    case transition = "ChimeTransition"
    /// ~1.5s, three notes resolving down to the tonic — audibly "done"; played
    /// when the autoplay queue is empty.
    case final = "ChimeFinal"
}

public enum ToneLibraryError: Error, Equatable {
    case resourceNotFound(ToneAsset)
    case fileReadFailed(ToneAsset)
    case conversionFailed(ToneAsset)
}

/// Loads bundled tone assets and converts them to an arbitrary target PCM
/// format (deinterleaved float32, to match `SpeechRenderer.canonicalFormat`).
public enum ToneLibrary {
    /// Decodes `asset` from the module's resource bundle and converts it to
    /// `format`. Pure/stateless — callers (namely `ArticleAudioEngine`) cache
    /// the result themselves since this does file I/O + conversion each call.
    public static func loadBuffer(_ asset: ToneAsset, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let url = Bundle.module.url(forResource: asset.rawValue, withExtension: "caf") else {
            throw ToneLibraryError.resourceNotFound(asset)
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw ToneLibraryError.fileReadFailed(asset)
        }
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw ToneLibraryError.fileReadFailed(asset)
        }
        do {
            try file.read(into: sourceBuffer)
        } catch {
            throw ToneLibraryError.fileReadFailed(asset)
        }

        do {
            let converted = try AudioFormatConversion.convert(
                [sourceBuffer], from: file.processingFormat, to: format)
            guard let outBuffer = converted.first else { throw ToneLibraryError.conversionFailed(asset) }
            return outBuffer
        } catch {
            throw ToneLibraryError.conversionFailed(asset)
        }
    }
}

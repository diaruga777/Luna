//
//  VoiceModelRegistry.swift
//  ReaderKit
//

import Foundation

/// A single file that makes up a downloadable neural-voice model.
struct VoiceModelFile: Sendable, Hashable {
    /// The remote source on Hugging Face.
    let remoteURL: URL
    /// The local filename it is saved as inside the model's App Group folder.
    let filename: String
    /// Approximate download size in bytes, for display only.
    let approximateBytes: Int64
}

/// The static catalogue of downloadable neural voices (Piper, Kokoro), with the
/// Hugging Face URLs and the files each one needs.
///
/// These are the canonical small/CPU-friendly checkpoints distributed on the
/// Hugging Face Hub. The ONNX model + its config (and, for Kokoro, the voice
/// embeddings) are downloaded into the App Group at runtime; nothing is bundled.
enum VoiceModelRegistry {

    /// The set of files for an engine kind, or `nil` for engines that don't
    /// download (basic / appleEnhanced).
    static func files(for kind: VoiceEngineKind) -> [VoiceModelFile]? {
        switch kind {
        case .basic, .appleEnhanced:
            return nil
        case .piper:
            // rhasspy/piper-voices — en_US "lessac" medium quality.
            let base = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/"
            return [
                VoiceModelFile(
                    remoteURL: URL(string: base + "en_US-lessac-medium.onnx")!,
                    filename: "en_US-lessac-medium.onnx",
                    approximateBytes: 63_000_000),
                VoiceModelFile(
                    remoteURL: URL(string: base + "en_US-lessac-medium.onnx.json")!,
                    filename: "en_US-lessac-medium.onnx.json",
                    approximateBytes: 5_000),
            ]
        case .kokoro:
            // hexgrad/Kokoro-82M — the int8 ONNX export + combined voices file.
            let base = "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/main/"
            return [
                VoiceModelFile(
                    remoteURL: URL(string: base + "onnx/model_quantized.onnx")!,
                    filename: "kokoro-v1.0.int8.onnx",
                    approximateBytes: 92_000_000),
                VoiceModelFile(
                    remoteURL: URL(string: base + "voices/af_heart.bin")!,
                    filename: "af_heart.bin",
                    approximateBytes: 524_000),
            ]
        }
    }

    /// Total approximate download size for an engine, in bytes (0 if none).
    static func totalApproximateBytes(for kind: VoiceEngineKind) -> Int64 {
        files(for: kind)?.reduce(0) { $0 + $1.approximateBytes } ?? 0
    }
}

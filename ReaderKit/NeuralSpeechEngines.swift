//
//  NeuralSpeechEngines.swift
//  ReaderKit
//

import AVFoundation

/// Shared behavior for the neural engines (Piper, Kokoro).
///
/// The download / select / delete lifecycle is fully real (see
/// `VoiceModelStore` + `VoiceModelDownloadManager`), but no ONNX / sherpa-onnx
/// runtime + phonemizer is vendored in this project yet, so we DO NOT fake
/// audio. For actual playback we route through the best installed Apple voice
/// (enhanced if present, else the system default) — which keeps the reader's
/// word-by-word highlighting working — and the settings row tells the user that
/// neural playback is arriving in a later update.
///
/// `isAvailable` reflects only whether the model files are present on disk, so
/// the engine can be selected once downloaded; the placeholder playback engine
/// is always usable.
private protocol NeuralSpeechEngine: SpeechEngine {}

extension NeuralSpeechEngine {
    var isAvailable: Bool { VoiceModelStore.isDownloaded(kind) }

    func configure(_ utterance: AVSpeechUtterance, rate: Float) {
        // TODO(neural-tts): once an ONNX/sherpa-onnx runtime + phonemizer is
        // vendored, render `utterance.speechString` with the downloaded model at
        // `VoiceModelStore.modelDirectory(for: kind)` and play the resulting
        // audio buffers, emitting word boundaries for highlighting. Until then,
        // speak through the best installed Apple voice so playback is real and
        // highlighting keeps working.
        let fallback = AppleEnhancedEngine()
        if fallback.isAvailable {
            fallback.configure(utterance, rate: rate)
        } else {
            BasicSpeechEngine().configure(utterance, rate: rate)
        }
    }
}

/// Piper neural voice (model downloaded from Hugging Face). Neural inference is
/// deferred — see `NeuralSpeechEngine`.
struct PiperEngine: NeuralSpeechEngine {
    let kind: VoiceEngineKind = .piper
}

/// Kokoro neural voice (model downloaded from Hugging Face). Neural inference is
/// deferred — see `NeuralSpeechEngine`.
struct KokoroEngine: NeuralSpeechEngine {
    let kind: VoiceEngineKind = .kokoro
}

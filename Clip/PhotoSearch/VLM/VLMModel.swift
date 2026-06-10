//
//  VLMModel.swift
//  clipper
//

import Foundation

/// A user-selectable on-device multimodal LLM used for the final "does this photo
/// contain X?" determination in applets (after the cheap CLIP candidate gate).
///
/// Unlike CLIP (a pair of small Core ML encoders), these are full vision-language
/// models that run on the MLX runtime. Weights are MLX checkpoints downloaded on
/// demand from HuggingFace as a whole-repository snapshot (config + tokenizer +
/// safetensors), stored in the App Group container so both the app and the
/// background ingest extension can load them. The default is the smallest model to
/// keep peak memory low — the extension runs under a tight memory ceiling.
enum VLMModel: String, CaseIterable, Sendable {
    case smolVLM2_256M
    case smolVLM2_500M
    case fastVLM_0_5B

    /// Smallest model — the default, chosen to minimize peak inference memory.
    static let defaultModel: VLMModel = .smolVLM2_256M

    /// HuggingFace repository hosting the MLX checkpoint.
    var huggingFaceRepo: String {
        switch self {
        case .smolVLM2_256M: return "mlx-community/SmolVLM2-256M-Video-Instruct-mlx"
        case .smolVLM2_500M: return "mlx-community/SmolVLM2-500M-Video-Instruct-mlx"
        case .fastVLM_0_5B: return "apple/FastVLM-0.5B-fp16"
        }
    }

    /// Pinned commit for reproducible downloads (so a repo update can't silently
    /// change the weights the app fetches).
    var huggingFaceRevision: String {
        switch self {
        case .smolVLM2_256M: return "c5d5c5c8c4b33e56c90d4b959a580ee2bd56ff98"
        case .smolVLM2_500M: return "61e6c96c3458a942a94f6e3cba1e4492fec5fdcb"
        // TODO: pin a commit SHA once FastVLM MLX integration is validated on device.
        case .fastVLM_0_5B: return "main"
        }
    }

    var displayName: String {
        switch self {
        case .smolVLM2_256M: return "SmolVLM2-256M"
        case .smolVLM2_500M: return "SmolVLM2-500M"
        case .fastVLM_0_5B: return "FastVLM-0.5B"
        }
    }

    var detail: String {
        switch self {
        case .smolVLM2_256M: return "Smallest · default · lowest memory"
        case .smolVLM2_500M: return "Larger · more accurate · more memory"
        case .fastVLM_0_5B: return "Apple · fastest first token · most memory"
        }
    }

    /// Rough on-disk download size, for the model picker UI. Approximate.
    var approximateDownloadMegabytes: Int {
        switch self {
        case .smolVLM2_256M: return 500
        case .smolVLM2_500M: return 1_000
        case .fastVLM_0_5B: return 1_100
        }
    }
}

//
//  VLMEngine.swift
//  clipper
//

import CoreGraphics
import Foundation

enum VLMEngineError: Error {
    case modelNotReady
    case inferenceFailed(Error)
    case unparseableResponse(String)
}

/// Runs the on-device multimodal LLM for the applet "contains" determination. The
/// concrete MLX-backed engine loads the model, runs a single constrained
/// yes/no inference for one image, and releases — callers (the ingest extension in
/// particular) process one asset at a time to keep peak memory low.
protocol VLMEngine: Sendable {
    /// Returns the model's final true/false judgement of whether `image` contains
    /// `query`. Implementations build a constrained prompt and parse a strict
    /// yes/no answer.
    func contains(image: CGImage, query: String) async throws -> Bool

    /// Releases the loaded model and frees GPU memory. Call when done with a batch of
    /// inferences so the large model isn't held resident (e.g. into backgrounding).
    func unload() async
}

//
//  PhotoFrameAnalyzer.swift
//  clipper
//

import CoreGraphics
import Foundation
import Vision

/// One photo's analysis for the index: its embedding (empty for label-only
/// analyzers) and the text it should be matched against (OCR, plus recognized
/// labels for the Vision baseline).
struct PhotoFrameAnalysis: Sendable {
    let embedding: [Float]
    let searchableText: String
}

/// Turns a single photo into a `PhotoFrameAnalysis`. Implementations back the
/// different photo-search models (CLIP embeddings vs Apple Vision labels).
protocol PhotoFrameAnalyzer: Sendable {
    /// Dimensionality of the embeddings produced (0 for label-only analyzers).
    var embeddingDimension: Int { get }

    /// Analyzes an image, or returns nil if it couldn't be processed.
    func analyze(image: CGImage) async -> PhotoFrameAnalysis?
}

/// Builds the analyzer for a selected model, or nil if the model isn't ready.
protocol PhotoFrameAnalyzerProvider: Sendable {
    func makeAnalyzer(for model: CLIPModel) -> PhotoFrameAnalyzer?
}

final class PhotoFrameAnalyzerProviderImpl: PhotoFrameAnalyzerProvider {

    private let engineProvider: CLIPEngineProvider
    private let textRecognizer: ImageTextRecognizer
    private let logger: Logger

    init(engineProvider: CLIPEngineProvider, textRecognizer: ImageTextRecognizer, logger: Logger) {
        self.engineProvider = engineProvider
        self.textRecognizer = textRecognizer
        self.logger = logger
    }

    func makeAnalyzer(for model: CLIPModel) -> PhotoFrameAnalyzer? {
        switch model.source {
        case .system:
            return VisionFrameAnalyzer(textRecognizer: textRecognizer)
        case .huggingFace, .bundled:
            guard let engine = engineProvider.makeEngine(for: model) else { return nil }
            return CLIPFrameAnalyzer(engine: engine, textRecognizer: textRecognizer, logger: logger)
        }
    }
}

/// CLIP analyzer: a photo's embedding comes from the image encoder; its
/// searchable text is the OCR result (literal text in the image).
final class CLIPFrameAnalyzer: PhotoFrameAnalyzer {

    let embeddingDimension: Int
    private let engine: CLIPEmbeddingEngine
    private let textRecognizer: ImageTextRecognizer
    private let logger: Logger

    init(engine: CLIPEmbeddingEngine, textRecognizer: ImageTextRecognizer, logger: Logger) {
        self.engine = engine
        self.embeddingDimension = engine.embeddingDimension
        self.textRecognizer = textRecognizer
        self.logger = logger
    }

    func analyze(image: CGImage) async -> PhotoFrameAnalysis? {
        do {
            let embedding = try await engine.imageEmbedding(for: image)
            let ocr = await textRecognizer.recognizeText(in: image)
            return PhotoFrameAnalysis(embedding: embedding, searchableText: ocr)
        } catch {
            logger.error("CLIP image embedding failed: \(error)")
            return nil
        }
    }
}

/// Apple Vision baseline: no embeddings. A photo's searchable text is its OCR
/// result plus the labels from Apple's on-device image classifier
/// (`VNClassifyImageRequest`), so text queries match recognized objects/scenes.
/// This is a closed-vocabulary comparison point against open-vocabulary CLIP.
final class VisionFrameAnalyzer: PhotoFrameAnalyzer {

    let embeddingDimension = 0
    private let textRecognizer: ImageTextRecognizer
    private let maxLabels = 12
    private let minConfidence: Float = 0.1

    init(textRecognizer: ImageTextRecognizer) {
        self.textRecognizer = textRecognizer
    }

    func analyze(image: CGImage) async -> PhotoFrameAnalysis? {
        let labels = await classify(image)
        let ocr = await textRecognizer.recognizeText(in: image)
        let text = ([ocr] + labels).filter { !$0.isEmpty }.joined(separator: " ")
        return PhotoFrameAnalysis(embedding: [], searchableText: text)
    }

    private func classify(_ image: CGImage) async -> [String] {
        await withCheckedContinuation { continuation in
            // `perform` calls the completion handler synchronously and may also
            // throw, so guard against resuming the continuation twice.
            var resumed = false
            func finish(_ labels: [String]) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: labels)
            }
            let request = VNClassifyImageRequest { request, _ in
                let observations = (request.results as? [VNClassificationObservation]) ?? []
                let labels = observations
                    .filter { $0.confidence >= self.minConfidence }
                    .prefix(self.maxLabels)
                    .map { $0.identifier.replacingOccurrences(of: "_", with: " ").lowercased() }
                finish(Array(labels))
            }
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                finish([])
            }
        }
    }
}

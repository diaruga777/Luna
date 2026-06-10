//
//  CLIPEngineProvider.swift
//  clipper
//

import Foundation
import UIKit

/// Builds a ready-to-use embedding engine for a model, wiring its compiled
/// encoders to the shared text tokenizer. Returns nil when the model has not been
/// downloaded yet.
protocol CLIPEngineProvider: Sendable {
    func makeEngine(for model: CLIPModel) -> CLIPEmbeddingEngine?
}

final class CLIPEngineProviderImpl: CLIPEngineProvider, @unchecked Sendable {

    private let modelManager: CLIPModelManager
    private let makeTokenizer: @Sendable () -> CLIPTextTokenizer
    private let logger: Logger

    // The tokenizer parses ~49k vocab entries; build it lazily so camera-mode
    // launches (the common case) pay nothing for Photo Search.
    private let lock = NSLock()
    private var cachedTokenizer: CLIPTextTokenizer?

    init(
        modelManager: CLIPModelManager,
        makeTokenizer: @escaping @Sendable () -> CLIPTextTokenizer,
        logger: Logger
    ) {
        self.modelManager = modelManager
        self.makeTokenizer = makeTokenizer
        self.logger = logger
    }

    func makeEngine(for model: CLIPModel) -> CLIPEmbeddingEngine? {
        guard
            modelManager.isDownloaded(model),
            let imageEncoderURL = modelManager.imageEncoderURL(for: model),
            let textEncoderURL = modelManager.textEncoderURL(for: model)
        else {
            return nil
        }
        return CoreMLCLIPEmbeddingEngine(
            model: model,
            imageEncoderURL: imageEncoderURL,
            textEncoderURL: textEncoderURL,
            tokenizer: tokenizer()
        )
    }

    private func tokenizer() -> CLIPTextTokenizer {
        lock.lock()
        defer { lock.unlock() }
        if let cachedTokenizer { return cachedTokenizer }
        let built = makeTokenizer()
        cachedTokenizer = built
        return built
    }
}

extension BPECLIPTokenizer {
    /// Loads the tokenizer from the `clip_merges` data set bundled in the app's
    /// asset catalog. Returns nil if the asset is missing.
    static func bundled() -> BPECLIPTokenizer? {
        let bundle = Bundle(for: BundleToken.self)
        guard
            let asset = NSDataAsset(name: "clip_merges", bundle: bundle),
            let contents = String(data: asset.data, encoding: .utf8)
        else {
            return nil
        }
        return BPECLIPTokenizer(mergesFileContents: contents)
    }
}

/// Anchor class used only to locate the module bundle that holds resources.
private final class BundleToken {}

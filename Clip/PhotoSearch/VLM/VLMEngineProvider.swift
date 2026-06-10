//
//  VLMEngineProvider.swift
//  clipper
//

import Foundation

/// Builds the VLM engine for a model, or nil if that model isn't downloaded yet.
protocol VLMEngineProvider: Sendable {
    func makeEngine(for model: VLMModel) -> VLMEngine?
}

final class VLMEngineProviderImpl: VLMEngineProvider {

    private let modelManager: VLMModelManager
    private let logger: Logger

    init(modelManager: VLMModelManager, logger: Logger) {
        self.modelManager = modelManager
        self.logger = logger
    }

    func makeEngine(for model: VLMModel) -> VLMEngine? {
        guard modelManager.isDownloaded(model),
              let directory = modelManager.modelURL(for: model) else {
            return nil
        }
        return MLXVLMEngine(modelDirectory: directory, logger: logger)
    }
}

//
//  PhotoIndexer.swift
//  clipper
//

import CoreGraphics
import Foundation

enum PhotoIndexerError: Error {
    case modelNotReady
}

/// Builds and maintains the on-device photo-search index: enumerates the photo
/// library, analyzes each image with the selected model (CLIP embedding or Apple
/// Vision labels) plus OCR, and persists the result.
protocol PhotoIndexer: Sendable {
    /// Indexes the photo library with the given model.
    ///
    /// - Parameters:
    ///   - model: the model to use. Switching models invalidates any existing
    ///     index (embeddings aren't comparable across models).
    ///   - force: when true, re-analyzes every asset; otherwise only assets
    ///     missing from the existing index are processed and deleted assets pruned.
    ///   - onProgress: fractional progress (0...1) on the indexing work.
    /// - Returns: the freshly persisted index. If cancelled, returns the partial
    ///   index built so far (also persisted).
    func reindex(
        model: CLIPModel,
        force: Bool,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> PhotoEmbeddingIndex
}

final class PhotoIndexerImpl: PhotoIndexer {

    private let assetSource: PhotoAssetSource
    private let analyzerProvider: PhotoFrameAnalyzerProvider
    private let indexStore: PhotoIndexStore
    private let logger: Logger

    /// Max concurrent per-asset pipelines (load → analyze). Bounded to keep peak
    /// memory and Neural Engine contention low.
    private let maxConcurrentAssets = 3

    init(
        assetSource: PhotoAssetSource,
        analyzerProvider: PhotoFrameAnalyzerProvider,
        indexStore: PhotoIndexStore,
        logger: Logger
    ) {
        self.assetSource = assetSource
        self.analyzerProvider = analyzerProvider
        self.indexStore = indexStore
        self.logger = logger
    }

    func reindex(
        model: CLIPModel,
        force: Bool,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> PhotoEmbeddingIndex {
        guard let analyzer = analyzerProvider.makeAnalyzer(for: model) else {
            throw PhotoIndexerError.modelNotReady
        }
        let embeddingDimension = analyzer.embeddingDimension

        let assets = assetSource.fetchImageAssets()
        let assetByID = Dictionary(assets.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first })

        // Seed surviving entries from the existing index unless we're rebuilding.
        let existing = try? indexStore.load()
        let reuseExisting = !force
            && existing?.modelIdentifier == model.rawValue
            && existing?.embeddingDimension == embeddingDimension
        var entriesByID: [String: PhotoIndexEntry] = [:]
        if reuseExisting, let existing {
            for entry in existing.entries where assetByID[entry.localIdentifier] != nil {
                entriesByID[entry.localIdentifier] = entry
            }
        }

        let pending = assets.filter { entriesByID[$0.localIdentifier] == nil }
        let total = pending.count

        guard total > 0 else {
            let index = PhotoEmbeddingIndex(
                modelIdentifier: model.rawValue,
                embeddingDimension: embeddingDimension,
                entries: Array(entriesByID.values)
            )
            try indexStore.save(index)
            onProgress(1)
            return index
        }

        let targetSize = model.imageInputSize
        var completed = 0
        var cancelled = false

        // Process in bounded batches: peak memory and Neural Engine contention
        // stay capped while still overlapping image load, embedding, and OCR.
        for start in stride(from: 0, to: pending.count, by: maxConcurrentAssets) {
            if Task.isCancelled {
                cancelled = true
                break
            }
            let batch = Array(pending[start..<min(start + maxConcurrentAssets, pending.count)])
            let entries = try await withThrowingTaskGroup(of: PhotoIndexEntry?.self) { group -> [PhotoIndexEntry] in
                for asset in batch {
                    group.addTask { [assetSource] in
                        guard let image = await assetSource.loadImage(
                            localIdentifier: asset.localIdentifier,
                            targetSize: targetSize
                        ) else {
                            return nil
                        }
                        guard let analysis = await analyzer.analyze(image: image) else { return nil }
                        return PhotoIndexEntry(
                            localIdentifier: asset.localIdentifier,
                            embedding: analysis.embedding,
                            ocrText: analysis.searchableText,
                            creationDate: asset.creationDate
                        )
                    }
                }
                var collected: [PhotoIndexEntry] = []
                for try await result in group {
                    if let result { collected.append(result) }
                }
                return collected
            }

            for entry in entries {
                entriesByID[entry.localIdentifier] = entry
            }
            completed += batch.count
            onProgress(Double(completed) / Double(total))
        }

        let index = PhotoEmbeddingIndex(
            modelIdentifier: model.rawValue,
            embeddingDimension: embeddingDimension,
            entries: Array(entriesByID.values)
        )
        try indexStore.save(index)
        if cancelled {
            logger.info("Photo indexing cancelled after \(completed)/\(total); saved partial index")
        }
        return index
    }
}

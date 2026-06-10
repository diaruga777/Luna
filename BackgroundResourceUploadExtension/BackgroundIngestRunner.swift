//
//  BackgroundIngestRunner.swift
//  BackgroundResourceUploadExtension
//

import Foundation
import Photos

/// Runs one bounded batch of background applet ingest. The system wakes the
/// extension via `process()`; we use that purely as an on-device hook (no uploads):
/// find photos not yet in the shared index, run the local pipeline (CLIP image
/// embed → applet cosine gate → VLM confirm → count + notify) on a few of them, and
/// report whether more remain so `process()` can return `.processing`/`.completed`.
///
/// Only a few assets are handled per invocation to bound peak memory (the VLM peaks
/// ~0.8–1.2 GB); the system re-invokes until we report we're caught up.
struct BackgroundIngestRunner {

    private let logger: Logger
    private let maxAssetsPerInvocation = 3

    init(logger: Logger) {
        self.logger = logger
    }

    /// Processes one batch. Returns true if more new photos remain (caller returns
    /// `.processing`), false when caught up (caller returns `.completed`).
    func runBatch() async -> Bool {
        let appletStore = AppletStoreImpl(logger: logger)
        guard let applets = try? appletStore.list(), !applets.isEmpty else { return false }

        guard let pipeline = makePipeline(appletStore: appletStore) else {
            // CLIP model or VLM not available to the extension (e.g. a bundled CLIP
            // model, or nothing downloaded). The in-app foreground observer covers
            // ingest when the app is open.
            return false
        }

        let indexed = Set((try? pipeline.indexStore.load())?.entries.map(\.localIdentifier) ?? [])
        let newAssets = pipeline.assetSource.fetchImageAssets()
            .filter { !indexed.contains($0.localIdentifier) }
        guard !newAssets.isEmpty else { return false }

        let batch = Array(newAssets.prefix(maxAssetsPerInvocation))
        logger.info("Background ingest: processing \(batch.count) of \(newAssets.count) new photos")
        for asset in batch {
            _ = await pipeline.processor.process(
                assetIdentifier: asset.localIdentifier,
                creationDate: asset.creationDate
            )
        }
        return newAssets.count > batch.count
    }

    // MARK: - Pipeline assembly

    private struct Pipeline {
        let processor: NewPhotoProcessor
        let indexStore: PhotoIndexStore
        let assetSource: PhotoAssetSource
    }

    private func makePipeline(appletStore: AppletStore) -> Pipeline? {
        let clipModel = CLIPModelStoreImpl().selectedModel
        let clipManager = CLIPModelManagerImpl(logger: logger)
        // The text encoder/tokenizer are unused here (applets carry precomputed
        // query embeddings), so a degraded empty-merge tokenizer is fine.
        let engineProvider = CLIPEngineProviderImpl(
            modelManager: clipManager,
            makeTokenizer: { BPECLIPTokenizer(mergesFileContents: "") },
            logger: logger
        )
        guard let clipEngine = engineProvider.makeEngine(for: clipModel) else { return nil }

        let vlmProvider = VLMEngineProviderImpl(modelManager: VLMModelManagerImpl(logger: logger), logger: logger)
        guard let vlmEngine = vlmProvider.makeEngine(for: VLMModelStoreImpl().selectedModel) else { return nil }

        let indexStore = PhotoIndexStoreImpl(logger: logger)
        let assetSource = PhotoKitAssetSource()
        let analyzer = CLIPFrameAnalyzer(
            engine: clipEngine,
            textRecognizer: VisionImageTextRecognizer(),
            logger: logger
        )
        let evaluator = AppletEvaluatorImpl(
            store: appletStore,
            clipEngine: clipEngine,
            vlmEngine: vlmEngine,
            notifier: AppletNotificationManagerImpl(),
            clipModelIdentifier: clipModel.rawValue,
            logger: logger
        )
        let processor = NewPhotoProcessorImpl(
            assetSource: assetSource,
            analyzer: analyzer,
            indexStore: indexStore,
            evaluator: evaluator,
            modelIdentifier: clipModel.rawValue,
            imageInputSize: clipModel.imageInputSize,
            logger: logger
        )
        return Pipeline(processor: processor, indexStore: indexStore, assetSource: assetSource)
    }
}

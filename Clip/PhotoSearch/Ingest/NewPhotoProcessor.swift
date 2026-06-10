//
//  NewPhotoProcessor.swift
//  clipper
//

import CoreGraphics
import Foundation

/// Processes a single newly-captured photo end to end on-device: analyze it (CLIP
/// embedding + OCR), append it to the shared index, then evaluate active applets
/// against it. This is the testable core shared by the background ingest extension
/// (woken by PhotoKit when a photo is added) and the in-app foreground observer;
/// the extension's entry point is a thin shell over this type.
///
/// To keep peak memory low (the extension runs under a tight ceiling), one photo is
/// processed at a time and its decoded image is reused for both analysis and VLM
/// confirmation rather than decoded twice.
protocol NewPhotoProcessor: Sendable {
    /// Analyzes, indexes, and evaluates one asset. Returns the applets that newly
    /// matched it (already recorded + notified by the evaluator).
    func process(assetIdentifier: String, creationDate: Date) async -> [Applet]
}

final class NewPhotoProcessorImpl: NewPhotoProcessor {

    private let assetSource: PhotoAssetSource
    private let analyzer: PhotoFrameAnalyzer
    private let indexStore: PhotoIndexStore
    private let evaluator: AppletEvaluator
    private let modelIdentifier: String
    private let imageInputSize: Int
    private let logger: Logger

    /// The image handed to the VLM for confirmation is decoded at this size, not the
    /// (much smaller) CLIP input size — a small VLM judging a 256px thumbnail produces
    /// false negatives. Only decoded for assets that clear the cheap CLIP gate.
    private let vlmImageInputSize = 768

    /// - Parameters:
    ///   - analyzer: built for the user's selected CLIP model; its embeddings must
    ///     match the model the evaluator embeds applet queries with.
    ///   - modelIdentifier/imageInputSize: the selected model's index identity and
    ///     source thumbnail size.
    init(
        assetSource: PhotoAssetSource,
        analyzer: PhotoFrameAnalyzer,
        indexStore: PhotoIndexStore,
        evaluator: AppletEvaluator,
        modelIdentifier: String,
        imageInputSize: Int,
        logger: Logger
    ) {
        self.assetSource = assetSource
        self.analyzer = analyzer
        self.indexStore = indexStore
        self.evaluator = evaluator
        self.modelIdentifier = modelIdentifier
        self.imageInputSize = imageInputSize
        self.logger = logger
    }

    func process(assetIdentifier: String, creationDate: Date) async -> [Applet] {
        // Fast path: the asset is already indexed for this model — reuse its
        // embedding and only decode the image if an applet becomes a candidate.
        if let existing = try? indexStore.load(),
           existing.modelIdentifier == modelIdentifier,
           let entry = existing.entries.first(where: { $0.localIdentifier == assetIdentifier }) {
            return await evaluator.evaluate(
                assetIdentifier: assetIdentifier,
                embedding: entry.embedding
            ) {
                await self.assetSource.loadImage(localIdentifier: assetIdentifier, targetSize: self.vlmImageInputSize)
            }
        }

        guard let image = await assetSource.loadImage(
            localIdentifier: assetIdentifier,
            targetSize: imageInputSize
        ) else {
            return []
        }
        guard let analysis = await analyzer.analyze(image: image) else { return [] }

        let entry = PhotoIndexEntry(
            localIdentifier: assetIdentifier,
            embedding: analysis.embedding,
            ocrText: analysis.searchableText,
            creationDate: creationDate
        )
        do {
            try indexStore.appendEntry(
                entry,
                modelIdentifier: modelIdentifier,
                embeddingDimension: analyzer.embeddingDimension
            )
        } catch {
            logger.error("Failed to append \(assetIdentifier) to index: \(error)")
        }

        // Decode a higher-resolution image for VLM confirmation (only invoked if an
        // applet clears the CLIP gate); the 256px CLIP image is too small for the VLM.
        return await evaluator.evaluate(
            assetIdentifier: assetIdentifier,
            embedding: analysis.embedding
        ) {
            await self.assetSource.loadImage(localIdentifier: assetIdentifier, targetSize: self.vlmImageInputSize)
        }
    }
}

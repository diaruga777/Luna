//
//  AppletEvaluator.swift
//  clipper
//

import CoreGraphics
import Foundation

/// Runs the two-step applet "contains" check for a single photo against all active
/// applets:
///   1. cheap gate — cosine(queryEmbedding, photoEmbedding) ≥ applet.threshold;
///   2. confirmation — the VLM's structured true/false on the full image.
/// On a confirmed, not-yet-counted match it records the capture and fires a
/// notification (when the applet has notifications enabled).
///
/// The full image is loaded lazily and only once, after at least one applet clears
/// the cheap gate — important for backfill, which would otherwise decode every
/// photo in the library.
protocol AppletEvaluator: Sendable {
    /// Evaluates `embedding` (the photo's CLIP embedding) against every active
    /// applet, loading the full image via `loadImage` only if needed. Returns the
    /// applets that newly matched this asset (already recorded + notified).
    func evaluate(
        assetIdentifier: String,
        embedding: [Float],
        loadImage: () async -> CGImage?
    ) async -> [Applet]
}

actor AppletEvaluatorImpl: AppletEvaluator {

    private let store: AppletStore
    private let clipEngine: CLIPEmbeddingEngine
    private let vlmEngine: VLMEngine
    private let notifier: AppletNotificationManager
    private let clipModelIdentifier: String
    private let logger: Logger

    /// Cache of query → text embedding for the current CLIP model. The engine is
    /// bound to one model, so the query string alone is a sufficient key.
    private var queryEmbeddingCache: [String: [Float]] = [:]

    /// - Parameter clipModelIdentifier: the `CLIPModel.rawValue` the photo
    ///   embeddings were produced with. An applet's precomputed `queryEmbedding` is
    ///   only used when it was produced with this same model.
    init(
        store: AppletStore,
        clipEngine: CLIPEmbeddingEngine,
        vlmEngine: VLMEngine,
        notifier: AppletNotificationManager,
        clipModelIdentifier: String,
        logger: Logger
    ) {
        self.store = store
        self.clipEngine = clipEngine
        self.vlmEngine = vlmEngine
        self.notifier = notifier
        self.clipModelIdentifier = clipModelIdentifier
        self.logger = logger
    }

    func evaluate(
        assetIdentifier: String,
        embedding: [Float],
        loadImage: () async -> CGImage?
    ) async -> [Applet] {
        guard !embedding.isEmpty else { return [] }
        let applets = (try? store.list()) ?? []

        // Step 1: cheap CLIP gate. Skip applets that already counted this asset.
        var candidates: [Applet] = []
        for applet in applets where !applet.matchedAssetIdentifiers.contains(assetIdentifier) {
            guard let queryEmbedding = await queryEmbedding(for: applet),
                  queryEmbedding.count == embedding.count else { continue }
            let similarity = Self.cosine(queryEmbedding, embedding)
            let passed = Double(similarity) >= applet.threshold
            logger.info("applet gate \"\(applet.query)\" sim=\(similarity) threshold=\(applet.threshold) passed=\(passed)")
            if passed {
                candidates.append(applet)
            }
        }
        guard !candidates.isEmpty else { return [] }

        // Load the full image once for VLM confirmation of all candidates.
        guard let image = await loadImage() else { return [] }

        // Step 2: VLM confirmation + record + notify.
        var matched: [Applet] = []
        for applet in candidates {
            let isMatch: Bool
            do {
                isMatch = try await vlmEngine.contains(image: image, query: applet.query)
            } catch {
                logger.error("VLM determination failed for applet \(applet.id): \(error)")
                continue
            }
            logger.info("applet VLM confirm \"\(applet.query)\" -> \(isMatch)")
            guard isMatch else { continue }

            let isNewMatch = (try? store.recordMatch(appletID: applet.id, assetID: assetIdentifier)) ?? false
            guard isNewMatch else { continue }
            matched.append(applet)
            if applet.notifyOnCapture {
                await notifier.notifyCapture(applet)
            }
        }
        return matched
    }

    /// The query's text embedding for the current CLIP model: the applet's
    /// precomputed value when it matches this model, otherwise computed via the
    /// CLIP text encoder (app path; the extension always has a matching precomputed
    /// value and so never needs the text encoder).
    private func queryEmbedding(for applet: Applet) async -> [Float]? {
        if let precomputed = applet.queryEmbedding,
           applet.queryEmbeddingModelIdentifier == clipModelIdentifier {
            return precomputed
        }
        let query = applet.query
        if let cached = queryEmbeddingCache[query] { return cached }
        do {
            let embedding = try await clipEngine.textEmbedding(for: query)
            queryEmbeddingCache[query] = embedding
            return embedding
        } catch {
            logger.error("Failed to embed applet query \"\(query)\": \(error)")
            return nil
        }
    }

    /// Cosine similarity of two L2-normalized vectors — a plain dot product.
    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for i in 0..<a.count { sum += a[i] * b[i] }
        return sum
    }
}

//
//  Applet.swift
//  clipper
//

import Foundation

/// A user-defined rule of the form "if a captured photo contains `query`, perform
/// an action." For the first pass the action is to increment `captureCount` and,
/// when `notifyOnCapture` is on, post a local notification.
///
/// `matchedAssetIdentifiers` records which photos have already satisfied this rule
/// so the same asset is never counted twice. This matters because evaluation runs
/// from three places that can see overlapping assets: the background ingest
/// extension, the in-app foreground photo-library observer, and the one-time
/// backfill over the existing index when the applet is created.
struct Applet: Codable, Sendable, Equatable, Identifiable {

    let id: UUID

    /// Human-facing label shown in the applet list. Defaults to `query` but can be
    /// edited independently.
    var name: String

    /// The user's "contains X" string. Embedded with the CLIP text encoder for the
    /// candidate gate, and passed verbatim to the VLM for the final determination.
    var query: String

    let createdAt: Date

    /// Number of distinct photos that have matched this rule.
    var captureCount: Int

    /// Whether a local notification fires on each new match.
    var notifyOnCapture: Bool

    /// Minimum CLIP cosine similarity for a photo to be a *candidate* (before VLM
    /// confirmation). Deliberately generous — the VLM makes the final call.
    var threshold: Double

    /// Local identifiers of photos already counted, so re-evaluation never
    /// double-counts the same asset.
    var matchedAssetIdentifiers: Set<String>

    /// The CLIP text embedding of `query`, precomputed in the app when the applet
    /// is created. Lets the background ingest extension run the cosine gate without
    /// the CLIP text encoder/tokenizer (smaller, lower-memory extension). Paired
    /// with `queryEmbeddingModelIdentifier`; only valid for that CLIP model.
    var queryEmbedding: [Float]?

    /// The `CLIPModel.rawValue` used to produce `queryEmbedding`. If it doesn't
    /// match the model that indexed a photo, the embedding is recomputed (app) or
    /// the applet is skipped (extension).
    var queryEmbeddingModelIdentifier: String?

    /// Generous default candidate threshold for the CLIP cosine gate. Tuned to let
    /// plausible matches through to the VLM rather than filtering aggressively.
    static let defaultThreshold: Double = 0.22

    init(
        id: UUID = UUID(),
        name: String,
        query: String,
        createdAt: Date,
        captureCount: Int = 0,
        notifyOnCapture: Bool = false,
        threshold: Double = Applet.defaultThreshold,
        matchedAssetIdentifiers: Set<String> = [],
        queryEmbedding: [Float]? = nil,
        queryEmbeddingModelIdentifier: String? = nil
    ) {
        self.id = id
        self.name = name
        self.query = query
        self.createdAt = createdAt
        self.captureCount = captureCount
        self.notifyOnCapture = notifyOnCapture
        self.threshold = threshold
        self.matchedAssetIdentifiers = matchedAssetIdentifiers
        self.queryEmbedding = queryEmbedding
        self.queryEmbeddingModelIdentifier = queryEmbeddingModelIdentifier
    }
}

//
//  PhotoSearchService.swift
//  clipper
//

import Accelerate
import Foundation

/// Ranks indexed photos for a text query by fusing semantic CLIP similarity with
/// literal OCR text matching. A blank query returns everything in reverse
/// chronological order.
protocol PhotoSearchService: Sendable {
    /// Replaces the in-memory index used for ranking.
    func setIndex(_ index: PhotoEmbeddingIndex) async

    /// Returns the local identifiers of photos that *match* the query, ranked
    /// best-first. A non-empty query narrows the result to photos above the
    /// semantic relevance floor or with an OCR text match; a blank query returns
    /// everything in reverse-chronological order.
    ///
    /// - Parameters:
    ///   - query: the raw search text (used for OCR matching).
    ///   - queryEmbedding: the query embedded in the CLIP space, or nil if it is
    ///     not available yet (then matching falls back to OCR only).
    func search(query: String, queryEmbedding: [Float]?) async -> [String]
}

actor PhotoSearchServiceImpl: PhotoSearchService {

    // Ranking weights. OCR exact-phrase matches additionally receive a large
    // additive boost so literal text in an image (receipts, signs, screenshots)
    // surfaces to the top regardless of semantic similarity.
    private static let semanticWeight: Float = 0.7
    private static let ocrWeight: Float = 0.3
    private static let exactPhraseBoost: Float = 1.0

    /// Minimum raw cosine similarity for a photo to count as a semantic match.
    /// Tuned against MobileCLIP-class models, where genuine matches score ≳0.15–0.30,
    /// weak/secondary matches ~0.12, and unrelated photos stay below ~0.10. Entries
    /// below the floor are dropped from results (a query narrows to its matches)
    /// unless they also match OCR text. Loosen toward recall / raise toward precision.
    private static let semanticRelevanceFloor: Float = 0.15

    /// Cap on returned results. The grid only ever shows a screenful, so bounding
    /// the result list keeps the per-keystroke snapshot diff + render cheap even
    /// over very large libraries. Ranked best-first, so this keeps the top matches.
    private static let maxResults = 500

    private var dimension = 0
    private var identifiers: [String] = []
    private var creationDates: [Date] = []
    private var ocrTexts: [String] = []
    /// Row-major N×dimension matrix of L2-normalized embeddings.
    private var matrix: [Float] = []
    /// Identifier order for a blank query: reverse chronological.
    private var chronological: [String] = []

    func setIndex(_ index: PhotoEmbeddingIndex) {
        dimension = index.embeddingDimension
        let sorted = index.entries.sorted { $0.creationDate > $1.creationDate }
        identifiers = sorted.map(\.localIdentifier)
        creationDates = sorted.map(\.creationDate)
        ocrTexts = sorted.map(\.ocrText)
        matrix = sorted.flatMap { entry -> [Float] in
            // Defend against a malformed entry whose vector length disagrees with
            // the declared dimension.
            if entry.embedding.count == dimension { return entry.embedding }
            var padded = entry.embedding
            padded.append(contentsOf: Array(repeating: 0, count: max(0, dimension - padded.count)))
            return Array(padded.prefix(dimension))
        }
        chronological = identifiers
    }

    func search(query: String, queryEmbedding: [Float]?) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return chronological }
        let count = identifiers.count
        guard count > 0 else { return [] }

        // Raw cosine similarity per entry (nil when no usable query embedding),
        // plus a [0,1] min-max normalization used only for ranking/fusion.
        let rawCosines = rawCosines(queryEmbedding: queryEmbedding, count: count)
        let semantic = Self.minMaxNormalized(rawCosines, count: count)
        let queryTokens = trimmed.split(separator: " ").map(String.init)

        var scored: [(index: Int, score: Float)] = []
        scored.reserveCapacity(count)
        for i in 0..<count {
            let ocr = ocrScore(text: ocrTexts[i], fullQuery: trimmed, tokens: queryTokens)

            // Relevance gate: narrow to photos that actually match. With a query
            // embedding, keep those above the cosine floor or with any OCR match.
            // Without one, we can't judge semantics — keep only OCR matches.
            let isRelevant: Bool
            if let rawCosines {
                isRelevant = rawCosines[i] >= Self.semanticRelevanceFloor || ocr.score > 0
            } else {
                isRelevant = ocr.score > 0
            }
            guard isRelevant else { continue }

            var score = Self.semanticWeight * semantic[i] + Self.ocrWeight * ocr.score
            if ocr.exactPhrase { score += Self.exactPhraseBoost }
            scored.append((i, score))
        }

        // Only fall back to the full (chronological) list when this is an
        // embedding-based index whose query vector was unavailable (a transient
        // engine failure) — never blank the grid in that case. A text-only index
        // (Apple Vision labels, dimension 0) legitimately returns no matches.
        if scored.isEmpty && queryEmbedding == nil && dimension > 0 { return chronological }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return creationDates[lhs.index] > creationDates[rhs.index]
        }
        let limit = min(scored.count, Self.maxResults)
        return scored[0..<limit].map { identifiers[$0.index] }
    }

    // MARK: - Semantic

    /// Per-entry raw cosine similarity (a dot product of L2-normalized vectors).
    /// Returns nil when no usable query embedding is available.
    private func rawCosines(queryEmbedding: [Float]?, count: Int) -> [Float]? {
        guard let query = queryEmbedding, query.count == dimension, dimension > 0, matrix.count >= count * dimension else {
            return nil
        }
        // All N dot products in one BLAS matrix-vector multiply: dots = matrix · query.
        // Far faster than N separate vDSP_dotpr calls over a large library.
        var dots = [Float](repeating: 0, count: count)
        matrix.withUnsafeBufferPointer { matrixPointer in
            query.withUnsafeBufferPointer { queryPointer in
                cblas_sgemv(
                    CblasRowMajor, CblasNoTrans,
                    Int32(count), Int32(dimension),
                    1, matrixPointer.baseAddress, Int32(dimension),
                    queryPointer.baseAddress, 1,
                    0, &dots, 1
                )
            }
        }
        return dots
    }

    /// Min-max normalizes values to [0, 1] for ranking. All zeros when values are
    /// nil or uniform.
    private static func minMaxNormalized(_ values: [Float]?, count: Int) -> [Float] {
        guard let values, let minValue = values.min(), let maxValue = values.max(), maxValue > minValue else {
            return [Float](repeating: 0, count: count)
        }
        let range = maxValue - minValue
        return values.map { ($0 - minValue) / range }
    }

    // MARK: - OCR

    private func ocrScore(text: String, fullQuery: String, tokens: [String]) -> (score: Float, exactPhrase: Bool) {
        guard !text.isEmpty, !tokens.isEmpty else { return (0, false) }
        let exactPhrase = fullQuery.count >= 2 && text.contains(fullQuery)
        let matched = tokens.reduce(into: 0) { count, token in
            if text.contains(token) { count += 1 }
        }
        let tokenScore = Float(matched) / Float(tokens.count)
        return (max(tokenScore, exactPhrase ? 1 : 0), exactPhrase)
    }
}

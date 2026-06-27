//
//  SemanticIndexer.swift
//  Clip
//

import ClipModels
import Foundation

/// Builds the semantic index and computes content-similarity sharing
/// suggestions. Two entry points, both gated by `SemanticSharingSettings`:
///
/// - `scheduleRun()` — MAIN APP ONLY. A background pass that embeds the items
///   you've shared to friends so future matches have that history to compare
///   against. Arms no suggestion.
/// - `immediateSuggestion(forItemID:)` — runs in the SAVE app-intent to drive
///   the live share/don't suggestion. Embeds ONLY the one just-saved item.
///
/// Each item is embedded as several PARAGRAPH CHUNKS (title + lead paragraphs),
/// and two items match on their closest chunk pair — so "both about Meta"
/// matches even when the wording differs. Logs copiously to the shared
/// diagnostic log (category "semantic") so the user can see it run.
final class SemanticIndexer {

    static let shared = SemanticIndexer()

    private static let embedLimit = 20
    private static let maxChunks = 8
    private static let maxChunkChars = 800

    private let queue = DispatchQueue(label: "com.hpiddy.clip.semanticindexer", qos: .utility)
    private let index = SemanticIndexStore.shared

    private func log(_ message: String) {
        SharedDiagnosticLog.record(message, category: "semantic")
    }

    // MARK: - Background indexing (main app)

    /// Indexing runs regardless of the experimental sharing flag — it now also
    /// powers semantic SEARCH over all saved content. (Only the share *suggestion*
    /// is gated by `SemanticSharingSettings`.) A no-op when nothing needs embedding,
    /// so it doesn't load the model unnecessarily.
    func scheduleRun() {
        queue.async { [weak self] in self?.buildMissingVectors() }
    }

    private func buildMissingVectors() {
        // Embed ALL saved items lacking vectors (for search), not just items shared
        // to friends.
        let allItemIDs = ReadingListStore.shared.items().map(\.id)
        let needed = index.itemIDsNeedingVectors(amongAll: allItemIDs, limit: Self.embedLimit)
        let stats = index.stats()
        log("index pass: \(needed.count) item(s) to embed; \(stats.persons) friend(s), \(stats.sharedItems) shared, \(stats.indexedItems) indexed")
        guard !needed.isEmpty else { return }
        let embedder = SemanticEmbedder()
        defer { embedder.release() }
        for itemID in needed {
            embedAndStore(itemID, embedder: embedder)
        }
    }

    /// Embeds an item's chunks and stores them (empty = tombstone). Returns the
    /// chunk count for logging.
    @discardableResult
    private func embedAndStore(_ itemID: UUID, embedder: SemanticEmbedder) -> Int {
        guard let item = ReadingListStore.shared.item(withID: itemID) else {
            index.setVectors([], forItemID: itemID)
            log("embed: item \(itemID.uuidString.prefix(8)) gone — tombstoned")
            return 0
        }
        let chunks = embeddingChunks(for: item)
        let vectors = chunks.compactMap { embedder.embed($0) }
        index.setVectors(vectors, forItemID: itemID)
        log("embed: \"\(item.title ?? item.urlString)\" → \(vectors.count) chunk vector(s) (dim \(vectors.first?.count ?? 0))")
        return vectors.count
    }

    // MARK: - Live suggestion (save intent)

    /// The friend to suggest sharing `itemID` with based on content similarity,
    /// or nil. Embeds the item now if needed (one item, chunked). Logs the
    /// nearest neighbor and score regardless of outcome.
    func immediateSuggestion(forItemID itemID: UUID) -> (uuid: UUID, username: String)? {
        guard SemanticSharingSettings.isEnabled else {
            log("suggestion skipped — feature disabled")
            return nil
        }
        // One model load for the whole batch: embed the just-saved item AND any
        // shared-history items still lacking vectors, so the match works even
        // before a background indexing pass has run (e.g. you just shared a few
        // articles, then saved a similar one via the share sheet).
        let embedder = SemanticEmbedder()
        defer { embedder.release() }
        if !index.hasVectors(forItemID: itemID) { embedAndStore(itemID, embedder: embedder) }
        for needID in index.itemIDsNeedingVectors(limit: Self.embedLimit) {
            embedAndStore(needID, embedder: embedder)
        }
        return evaluate(itemID, context: "save")
    }

    /// A cached-only match (no embedding) for the end-of-article affordance.
    func cachedSuggestion(forItemID itemID: UUID) -> (uuid: UUID, username: String)? {
        guard SemanticSharingSettings.isEnabled, index.hasVectors(forItemID: itemID) else { return nil }
        return evaluate(itemID, context: "reader")
    }

    private func evaluate(_ itemID: UUID, context: String) -> (uuid: UUID, username: String)? {
        var bestScore: Float = 0
        var bestUsername: String?
        var bestItemID: UUID?
        let threshold = SemanticSharingSettings.similarityThreshold
        let match = index.bestMatch(
            forItemID: itemID, threshold: threshold,
            bestScore: &bestScore, bestUsername: &bestUsername, bestItemID: &bestItemID)
        let neighborTitle = bestItemID.flatMap { ReadingListStore.shared.item(withID: $0)?.title } ?? "—"
        log("\(context): nearest = \"\(neighborTitle)\" shared to \(bestUsername ?? "—") score \(String(format: "%.3f", bestScore)) (threshold \(String(format: "%.2f", threshold)))")
        guard let match, FriendsStore.shared.friend(withUUID: match.uuid) != nil else {
            log("\(context): no suggestion (below threshold or friend missing)")
            return nil
        }
        log("\(context): suggesting \(match.username)")
        return (match.uuid, match.username)
    }

    // MARK: - Chunking

    /// Paragraph chunks for an item: a head built from the item's CONTENT metadata
    /// (title, channel, media creator/title) — never the URL — then lead article
    /// blocks. Media items (YouTube, posts, music/podcast) thus get embedded on
    /// their real content (what they're about), so they surface in semantic search.
    private func embeddingChunks(for item: ReadingListItem) -> [String] {
        var chunks: [String] = []
        let headParts = [
            item.title, item.channelName, item.mediaCreatorName, item.mediaItemTitle,
        ].compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let head = headParts.joined(separator: ". ")
        if !head.isEmpty { chunks.append(head) }
        if let content = ReadingListStore.shared.content(for: item) {
            for block in content.blocks where !block.text.trimmingCharacters(in: .whitespaces).isEmpty {
                chunks.append(String(block.text.prefix(Self.maxChunkChars)))
                if chunks.count >= Self.maxChunks { break }
            }
        }
        return chunks
    }
}

//
//  SemanticIndexer.swift
//  Clip
//

import Foundation

/// Builds the semantic index and arms semantic sharing suggestions. MAIN APP
/// ONLY — it loads the embedding model, so it must never run in the App-Intent
/// runner (call `scheduleRun()` from app lifecycle, not from intents).
///
/// Memory discipline: work is serialized on a single utility queue, a single
/// embedder is used per batch and released immediately after, and the number of
/// items embedded per run is capped. Vectors persist to disk so they're never
/// recomputed.
final class SemanticIndexer {

    static let shared = SemanticIndexer()

    /// Max items embedded per run (≥ the store's per-run check cap so every
    /// dequeued check has its vector ready).
    private static let embedLimit = 20

    private let queue = DispatchQueue(label: "com.hpiddy.clip.semanticindexer", qos: .utility)
    private let index = SemanticIndexStore.shared

    /// Kicks an indexing + suggestion pass on a background queue, if the
    /// experimental feature is on. Safe to call on every launch/foreground.
    func scheduleRun() {
        guard SemanticSharingSettings.isEnabled else { return }
        queue.async { [weak self] in self?.run() }
    }

    private func run() {
        // 1. Embed any referenced items still lacking a vector (main app only).
        let needed = index.itemIDsNeedingVectors(limit: Self.embedLimit)
        if !needed.isEmpty {
            let embedder = SemanticEmbedder()
            for itemID in needed {
                guard let item = ReadingListStore.shared.item(withID: itemID),
                      let vector = embedder.embed(embeddingText(for: item)) else {
                    // Item gone or unembeddable: store an empty tombstone vector
                    // so we don't keep retrying it forever.
                    index.setVector([], forItemID: itemID)
                    continue
                }
                index.setVector(vector, forItemID: itemID)
            }
            embedder.release()
        }

        // 2. Arm a semantic suggestion for each queued new save that now has a
        //    vector and is close to something already shared to a friend.
        for itemID in index.dequeueChecks() {
            guard index.hasVector(forItemID: itemID),
                  let match = index.bestMatch(forItemID: itemID),
                  let item = ReadingListStore.shared.item(withID: itemID),
                  FriendsStore.shared.friend(withUUID: match.uuid) != nil,
                  ShareSuggestionStore.shared.pendingSuggestion() == nil
            else { continue }
            ShareSuggestionStore.shared.armSemanticSuggestion(
                urlString: item.urlString, friendUUID: match.uuid, friendUsername: match.username)
            DiagnosticLog.shared.record(
                "semantic suggestion: \(match.username) (score \(String(format: "%.2f", match.score)))",
                category: "social")
        }
    }

    /// The text embedded for an item: title + channel + a sample of the body.
    private func embeddingText(for item: ReadingListItem) -> String {
        var parts: [String] = []
        if let title = item.title, !title.isEmpty { parts.append(title) }
        if let channel = item.channelName, !channel.isEmpty { parts.append(channel) }
        if let content = ReadingListStore.shared.content(for: item) {
            let body = content.blocks.prefix(8)
                .map(\.text).joined(separator: " ")
            if !body.isEmpty { parts.append(body) }
        }
        return parts.joined(separator: ". ")
    }
}

//
//  SemanticIndexer.swift
//  Clip
//

import Foundation

/// Builds the semantic index and computes content-similarity sharing
/// suggestions. Two entry points, both gated by `SemanticSharingSettings`:
///
/// - `scheduleRun()` — MAIN APP ONLY. A background pass that embeds the items
///   you've shared to friends so future matches have that history to compare
///   against. It does NOT arm any suggestion (suggestions on past saves at
///   launch would be terrible UX).
/// - `immediateSuggestion(forItemID:)` — runs in the SAVE app-intent (and the
///   in-app add) to drive the live share/don't suggestion. It embeds ONLY the
///   one just-saved item (a single inference, then the model is released) and
///   compares it to the already-cached per-friend vectors.
///
/// Memory: one embedder per call, released immediately; the launch pass is
/// capped and serialized on a utility queue. Vectors persist so they're never
/// recomputed.
final class SemanticIndexer {

    static let shared = SemanticIndexer()

    private static let embedLimit = 20

    private let queue = DispatchQueue(label: "com.hpiddy.clip.semanticindexer", qos: .utility)
    private let index = SemanticIndexStore.shared

    /// Background pass (main app): embed shared-but-unindexed items. No
    /// suggestion side effects. Safe to call on every launch/foreground.
    func scheduleRun() {
        guard SemanticSharingSettings.isEnabled else { return }
        queue.async { [weak self] in self?.buildMissingVectors() }
    }

    private func buildMissingVectors() {
        let needed = index.itemIDsNeedingVectors(limit: Self.embedLimit)
        guard !needed.isEmpty else { return }
        let embedder = SemanticEmbedder()
        defer { embedder.release() }
        for itemID in needed {
            guard let item = ReadingListStore.shared.item(withID: itemID),
                  let vector = embedder.embed(embeddingText(for: item)) else {
                index.setVector([], forItemID: itemID) // tombstone: don't retry
                continue
            }
            index.setVector(vector, forItemID: itemID)
        }
    }

    /// The friend to suggest sharing `itemID` with based on content similarity,
    /// or nil. Embeds the item now (one inference) if it isn't already indexed.
    /// Returns nil immediately when the feature is off. Intended for the save
    /// app-intent — keep heavier batch work out of the intent runner.
    func immediateSuggestion(forItemID itemID: UUID) -> (uuid: UUID, username: String)? {
        guard SemanticSharingSettings.isEnabled else { return nil }
        if !index.hasVector(forItemID: itemID),
           let item = ReadingListStore.shared.item(withID: itemID) {
            let embedder = SemanticEmbedder()
            defer { embedder.release() }
            index.setVector(embedder.embed(embeddingText(for: item)) ?? [], forItemID: itemID)
        }
        guard let match = index.bestMatch(forItemID: itemID),
              FriendsStore.shared.friend(withUUID: match.uuid) != nil
        else { return nil }
        return (match.uuid, match.username)
    }

    /// A cached-only similarity match (no embedding) for the end-of-article
    /// share affordance — cheap, returns nil if the item isn't indexed yet.
    func cachedSuggestion(forItemID itemID: UUID) -> (uuid: UUID, username: String)? {
        guard SemanticSharingSettings.isEnabled,
              let match = index.bestMatch(forItemID: itemID),
              FriendsStore.shared.friend(withUUID: match.uuid) != nil
        else { return nil }
        return (match.uuid, match.username)
    }

    /// The text embedded for an item: title + channel + a sample of the body.
    private func embeddingText(for item: ReadingListItem) -> String {
        var parts: [String] = []
        if let title = item.title, !title.isEmpty { parts.append(title) }
        if let channel = item.channelName, !channel.isEmpty { parts.append(channel) }
        if let content = ReadingListStore.shared.content(for: item) {
            let body = content.blocks.prefix(8).map(\.text).joined(separator: " ")
            if !body.isEmpty { parts.append(body) }
        }
        return parts.joined(separator: ". ")
    }
}

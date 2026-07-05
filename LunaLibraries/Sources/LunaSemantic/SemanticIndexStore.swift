//
//  SemanticIndexStore.swift
//  LunaSemantic
//

import LunaStorage
import Foundation

/// Persistent (App Group JSON) store backing semantic SEARCH.
///
/// Holds the embedding vectors of each saved item (one per paragraph chunk, for
/// finer-grained matching). The expensive part — computing vectors — is done
/// elsewhere (`SemanticIndexer`). Everything here is cheap float/JSON work:
/// `nearestItems` is cosine comparisons over small vectors. No model is loaded.
public final class SemanticIndexStore {

    public static let shared = SemanticIndexStore()

    // Holds vectors for the whole saved library (semantic search indexes everything),
    // so this is generous; eviction only kicks in for very large libraries.
    private static let maxIndexedItems = 2000

    private struct State: Codable {
        /// itemID → its paragraph-chunk vectors (empty array = indexed but no
        /// usable text: a tombstone so we don't keep retrying it).
        var itemVectors: [String: [[Float]]] = [:]
    }

    private let fileManager = FileManager.default
    private let overrideContainerURL: URL?
    private let lock = NSLock()

    public init(containerURL: URL? = nil) { self.overrideContainerURL = containerURL }

    private var fileURL: URL {
        let container = overrideContainerURL
            ?? fileManager.containerURL(forSecurityApplicationGroupIdentifier: ReadingListStore.appGroupID)
            ?? fileManager.temporaryDirectory
        let url = container.appendingPathComponent("semanticIndex.json")
        BackupPolicy.excludeFromBackups(url)
        return url
    }

    // MARK: - Cheap operations

    public func hasVectors(forItemID itemID: UUID) -> Bool {
        loadState().itemVectors[itemID.uuidString] != nil
    }

    /// How many items are indexed (for logging).
    public func indexedItemCount() -> Int { loadState().itemVectors.count }

    /// Highest cosine over every pair of chunk vectors between two items.
    public static func maxChunkSimilarity(_ a: [[Float]], _ b: [[Float]]) -> Float {
        var top: Float = 0
        for x in a {
            for y in b { top = max(top, cosine(x, y)) }
        }
        return top
    }

    /// Cosine similarity of two equal-length vectors (0 if degenerate).
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom > 0 ? dot / denom : 0
    }

    // MARK: - Main-app operations (called by SemanticIndexer)

    /// Of the given reading-list item ids (in order), those lacking vectors — so
    /// the indexer can embed ALL saved content for search.
    public func itemIDsNeedingVectors(amongAll ids: [UUID], limit: Int) -> [UUID] {
        let state = loadState()
        var needed: [UUID] = []
        for id in ids where state.itemVectors[id.uuidString] == nil {
            needed.append(id)
            if needed.count >= limit { break }
        }
        return needed
    }

    /// Items most similar to the query's chunk vectors — scored by best chunk-pair
    /// cosine, kept at/above `threshold`, `excluded` ids removed, best first. Backs
    /// semantic search; pure float work, no model load.
    public func nearestItems(
        toVectors query: [[Float]], threshold: Float, excluding excluded: Set<UUID>, limit: Int
    ) -> [(itemID: UUID, score: Float)] {
        guard !query.isEmpty else { return [] }
        let state = loadState()
        var scored: [(UUID, Float)] = []
        for (key, vectors) in state.itemVectors {
            guard !vectors.isEmpty, let id = UUID(uuidString: key), !excluded.contains(id) else { continue }
            let score = Self.maxChunkSimilarity(query, vectors)
            if score >= threshold { scored.append((id, score)) }
        }
        scored.sort { $0.1 > $1.1 }
        return scored.prefix(limit).map { (itemID: $0.0, score: $0.1) }
    }

    public func setVectors(_ vectors: [[Float]], forItemID itemID: UUID) {
        mutate { state in
            state.itemVectors[itemID.uuidString] = vectors
            if state.itemVectors.count > Self.maxIndexedItems {
                // Deterministic eviction, never the just-stored key: dictionary
                // key order is hash-randomized, so iterating `keys` could evict
                // the item we just embedded — which would then be re-embedded
                // on the next indexing pass, churning forever.
                let evictable = state.itemVectors.keys
                    .filter { $0 != itemID.uuidString }
                    .sorted()
                for key in evictable.prefix(state.itemVectors.count - Self.maxIndexedItems) {
                    state.itemVectors.removeValue(forKey: key)
                }
            }
        }
    }

    // MARK: - Persistence

    private func loadState() -> State {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(State.self, from: data)
        else { return State() }
        return state
    }

    private func mutate(_ body: (inout State) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var state = loadState()
        body(&state)
        if let data = try? JSONEncoder().encode(state) {
            let url = fileURL
            try? data.write(to: url, options: .atomic)
            BackupPolicy.excludeFromBackups(url)
        }
    }
}

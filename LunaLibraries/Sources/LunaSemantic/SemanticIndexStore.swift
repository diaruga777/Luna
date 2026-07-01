//
//  SemanticIndexStore.swift
//  Luna
//

import LunaStorage
import Foundation

/// Persistent (App Group JSON) store backing semantic sharing suggestions.
///
/// Holds the embedding vectors of each saved item (one per paragraph chunk, for
/// finer-grained matching) and, per friend, the ids of items shared to them.
/// The expensive part — computing vectors — is done elsewhere
/// (`SemanticIndexer`). Everything here is cheap float/JSON work safe to call
/// from the App-Intent runner: recording a share appends an id, and `bestMatch`
/// is cosine comparisons over small vectors. No model is ever loaded.
public final class SemanticIndexStore {

    public static let shared = SemanticIndexStore()

    private static let maxItemsPerPerson = 60
    // Holds vectors for the whole saved library (semantic search indexes everything),
    // so this is generous; eviction only kicks in for very large libraries.
    private static let maxIndexedItems = 2000

    public struct Person: Codable {
        var username: String
        var itemIDs: [String] = []
    }

    private struct State: Codable {
        /// itemID → its paragraph-chunk vectors (empty array = indexed but no
        /// usable text: a tombstone so we don't keep retrying it).
        var itemVectors: [String: [[Float]]] = [:]
        var persons: [String: Person] = [:]
    }

    /// The best content-similarity hit for a query item.
    public struct Match {
        public let uuid: UUID
        public let username: String
        public let score: Float
        /// The friend's previously-shared item that matched (for logging).
        public let matchedItemID: UUID?

        public init(uuid: UUID, username: String, score: Float, matchedItemID: UUID?) {
            self.uuid = uuid
            self.username = username
            self.score = score
            self.matchedItemID = matchedItemID
        }
    }

    private let fileManager = FileManager.default
    private let overrideContainerURL: URL?
    private let lock = NSLock()

    public init(containerURL: URL? = nil) { self.overrideContainerURL = containerURL }

    private var fileURL: URL {
        let container = overrideContainerURL
            ?? fileManager.containerURL(forSecurityApplicationGroupIdentifier: ReadingListStore.appGroupID)
            ?? fileManager.temporaryDirectory
        return container.appendingPathComponent("semanticIndex.json")
    }

    // MARK: - Cheap operations (runner-safe)

    /// Records that `itemID` was shared to a friend (no vector needed now).
    public func recordShare(itemID: UUID, personUUID: UUID, username: String) {
        mutate { state in
            var person = state.persons[personUUID.uuidString] ?? Person(username: username)
            person.username = username
            let key = itemID.uuidString
            person.itemIDs.removeAll { $0 == key }
            person.itemIDs.append(key)
            if person.itemIDs.count > Self.maxItemsPerPerson {
                person.itemIDs.removeFirst(person.itemIDs.count - Self.maxItemsPerPerson)
            }
            state.persons[personUUID.uuidString] = person
        }
    }

    public func hasVectors(forItemID itemID: UUID) -> Bool {
        loadState().itemVectors[itemID.uuidString] != nil
    }

    /// How many friends and total shared-item references exist (for logging).
    public func stats() -> (persons: Int, sharedItems: Int, indexedItems: Int) {
        let state = loadState()
        return (state.persons.count,
                state.persons.values.reduce(0) { $0 + $1.itemIDs.count },
                state.itemVectors.count)
    }

    /// The friend whose previously-shared items are most semantically similar to
    /// `itemID` (max cosine over every chunk pair), at or above `threshold` and
    /// not already shared this item. nil when the item isn't indexed or nothing
    /// is close enough — but the best sub-threshold score is still reported via
    /// the `bestScore` out-param for logging.
    public func bestMatch(forItemID itemID: UUID, threshold: Float,
                   bestScore: inout Float, bestUsername: inout String?,
                   bestItemID: inout UUID?) -> Match? {
        let state = loadState()
        bestScore = 0; bestUsername = nil; bestItemID = nil
        guard let query = state.itemVectors[itemID.uuidString], !query.isEmpty else { return nil }
        var match: Match?
        for (uuidString, person) in state.persons {
            guard let uuid = UUID(uuidString: uuidString) else { continue }
            if person.itemIDs.contains(itemID.uuidString) { continue } // already shared
            for sharedID in person.itemIDs {
                guard let other = state.itemVectors[sharedID], !other.isEmpty else { continue }
                let score = Self.maxChunkSimilarity(query, other)
                if score > bestScore {
                    bestScore = score
                    bestUsername = person.username
                    bestItemID = UUID(uuidString: sharedID)
                }
                if score >= threshold, score > (match?.score ?? 0) {
                    match = Match(uuid: uuid, username: person.username, score: score,
                                  matchedItemID: UUID(uuidString: sharedID))
                }
            }
        }
        return match
    }

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

    /// Item ids shared to someone but lacking vectors — the main-app indexer
    /// embeds these so future matches have the recipient's history to compare to.
    public func itemIDsNeedingVectors(limit: Int) -> [UUID] {
        let state = loadState()
        var needed: [String] = []
        var seen = Set<String>()
        for key in state.persons.values.flatMap(\.itemIDs) where state.itemVectors[key] == nil {
            if seen.insert(key).inserted { needed.append(key) }
        }
        return needed.prefix(limit).compactMap { UUID(uuidString: $0) }
    }

    /// Of the given reading-list item ids (in order), those lacking vectors — so
    /// the indexer can embed ALL saved content for search, not just shared items.
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
                let referenced = Set(state.persons.values.flatMap(\.itemIDs))
                for key in state.itemVectors.keys where !referenced.contains(key) {
                    state.itemVectors.removeValue(forKey: key)
                    if state.itemVectors.count <= Self.maxIndexedItems { break }
                }
            }
        }
    }

    public func removePerson(_ personUUID: UUID) {
        mutate { state in state.persons.removeValue(forKey: personUUID.uuidString) }
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
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

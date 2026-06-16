//
//  SemanticIndexStore.swift
//  Clip
//

import Foundation

/// Persistent (App Group JSON) store backing semantic sharing suggestions.
///
/// Holds one embedding vector per saved item and, per friend, the ids of items
/// shared to them. The expensive part — computing vectors — is done elsewhere
/// (`SemanticIndexer`, MAIN APP ONLY). Everything here is cheap float/JSON work
/// safe to call from the App-Intent runner: recording a share appends an id,
/// and `bestMatch` is a handful of cosine comparisons. No model is ever loaded.
final class SemanticIndexStore {

    static let shared = SemanticIndexStore()

    /// Minimum cosine similarity to suggest sharing. Sentence-embedding cosines
    /// for clearly related text sit well above this; unrelated text below.
    static let similarityThreshold: Float = 0.60
    private static let maxItemsPerPerson = 60
    private static let maxIndexedItems = 600

    struct Person: Codable {
        var username: String
        var itemIDs: [String] = []
    }

    private struct State: Codable {
        var itemVectors: [String: [Float]] = [:]
        var persons: [String: Person] = [:]
    }

    struct Match {
        let uuid: UUID
        let username: String
        let score: Float
    }

    private let fileManager = FileManager.default
    private let overrideContainerURL: URL?
    private let lock = NSLock()

    init(containerURL: URL? = nil) { self.overrideContainerURL = containerURL }

    private var fileURL: URL {
        let container = overrideContainerURL
            ?? fileManager.containerURL(forSecurityApplicationGroupIdentifier: ReadingListStore.appGroupID)
            ?? fileManager.temporaryDirectory
        return container.appendingPathComponent("semanticIndex.json")
    }

    // MARK: - Cheap operations (runner-safe)

    /// Records that `itemID` was shared to a friend (no vector needed now).
    func recordShare(itemID: UUID, personUUID: UUID, username: String) {
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

    func hasVector(forItemID itemID: UUID) -> Bool {
        loadState().itemVectors[itemID.uuidString] != nil
    }

    func vector(forItemID itemID: UUID) -> [Float]? {
        loadState().itemVectors[itemID.uuidString]
    }

    /// The friend whose previously-shared items are most semantically similar to
    /// `itemID`, above the threshold and not already shared this item. nil when
    /// the item isn't indexed or nothing is close enough.
    func bestMatch(forItemID itemID: UUID) -> Match? {
        let state = loadState()
        guard let vector = state.itemVectors[itemID.uuidString] else { return nil }
        var best: Match?
        for (uuidString, person) in state.persons {
            guard let uuid = UUID(uuidString: uuidString) else { continue }
            if person.itemIDs.contains(itemID.uuidString) { continue } // already shared
            var top: Float = 0
            for sharedID in person.itemIDs {
                guard let other = state.itemVectors[sharedID] else { continue }
                top = max(top, Self.cosine(vector, other))
            }
            if top >= Self.similarityThreshold, top > (best?.score ?? 0) {
                best = Match(uuid: uuid, username: person.username, score: top)
            }
        }
        return best
    }

    /// Cosine similarity of two equal-length vectors (0 if degenerate).
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
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

    /// Item ids shared to someone but lacking a vector — the main-app indexer
    /// embeds these so future matches have the recipient's history to compare to.
    func itemIDsNeedingVectors(limit: Int) -> [UUID] {
        let state = loadState()
        var needed: [String] = []
        var seen = Set<String>()
        for key in state.persons.values.flatMap(\.itemIDs) where state.itemVectors[key] == nil {
            if seen.insert(key).inserted { needed.append(key) }
        }
        return needed.prefix(limit).compactMap { UUID(uuidString: $0) }
    }

    func setVector(_ vector: [Float], forItemID itemID: UUID) {
        mutate { state in
            state.itemVectors[itemID.uuidString] = vector
            if state.itemVectors.count > Self.maxIndexedItems {
                // Drop vectors no longer referenced by any person.
                let referenced = Set(state.persons.values.flatMap(\.itemIDs))
                for key in state.itemVectors.keys where !referenced.contains(key) {
                    state.itemVectors.removeValue(forKey: key)
                    if state.itemVectors.count <= Self.maxIndexedItems { break }
                }
            }
        }
    }

    func removePerson(_ personUUID: UUID) {
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

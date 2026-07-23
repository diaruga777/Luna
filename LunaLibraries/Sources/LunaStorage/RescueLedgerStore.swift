//
//  RescueLedgerStore.swift
//  LunaStorage
//

import Foundation
import LunaAppConfig
import LunaModels

/// Per-item rescue bookkeeping — how many automatic attempts an item has had,
/// when, whether one succeeded (provenance). Kept in a SIDECAR file, never on
/// `ReadingListItem`: an older sibling app decoding/re-encoding the shared
/// `readingList.json` would silently drop unknown keys, wiping the bookkeeping
/// and causing re-LLM churn. A sidecar only the rescue layer touches avoids that
/// and keeps the hot shared model untouched (same reasoning as the imageRefs /
/// preloads sidecars).
public struct RescueLedgerEntry: Codable, Equatable {
    public var attemptCount: Int
    public var lastAttemptDate: Date?
    /// Provenance marker: this item was recovered by the rescue engine.
    public var succeeded: Bool
    public var lastHint: RescueHint?

    public init(attemptCount: Int = 0, lastAttemptDate: Date? = nil,
                succeeded: Bool = false, lastHint: RescueHint? = nil) {
        self.attemptCount = attemptCount
        self.lastAttemptDate = lastAttemptDate
        self.succeeded = succeeded
        self.lastHint = lastHint
    }
}

/// App-Group-backed ledger, written to `rescueLedger.json` beside the reading
/// list. The main app is the only LLM runner (this store's writers), so a lock +
/// atomic write suffices. "In-flight" is deliberately NOT persisted (a crash must
/// not strand an item) — the coordinator tracks that in process memory.
public final class RescueLedgerStore {
    public static let shared = RescueLedgerStore()

    /// Automatic rescue budget: at most this many lifetime auto-attempts per item.
    public static let maxAutoAttempts = 2
    /// Minimum spacing between automatic attempts.
    public static let autoRetrySpacing: TimeInterval = 24 * 60 * 60

    private let fileURL: URL?
    private let now: () -> Date
    private let lock = NSLock()
    private var entries: [String: RescueLedgerEntry]   // key = item UUID string

    public init(containerURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.now = now
        let base = containerURL ?? FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupID)
        self.fileURL = base?.appendingPathComponent("rescueLedger.json")
        self.entries = [:]
        loadFromDisk()
    }

    /// Whether an automatic rescue is allowed for this item now — under the
    /// attempt cap and past the spacing window. Manual one-shots ignore this.
    public func shouldAutoRescue(_ itemID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[itemID.uuidString] else { return true }
        guard entry.attemptCount < Self.maxAutoAttempts else { return false }
        guard let last = entry.lastAttemptDate else { return true }
        return now().timeIntervalSince(last) >= Self.autoRetrySpacing
    }

    public func recordAttempt(_ itemID: UUID, hint: RescueHint?) {
        mutate(itemID) { entry in
            entry.attemptCount += 1
            entry.lastAttemptDate = self.now()
            if let hint { entry.lastHint = hint }
        }
    }

    public func recordSuccess(_ itemID: UUID, hint: RescueHint?) {
        mutate(itemID) { entry in
            entry.succeeded = true
            if let hint { entry.lastHint = hint }
        }
    }

    public func wasRescued(_ itemID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[itemID.uuidString]?.succeeded ?? false
    }

    public func entry(_ itemID: UUID) -> RescueLedgerEntry? {
        lock.lock(); defer { lock.unlock() }
        return entries[itemID.uuidString]
    }

    /// Drops ledger rows for items no longer present (called from the sweep).
    public func prune(keeping ids: Set<UUID>) {
        lock.lock(); defer { lock.unlock() }
        let keys = Set(ids.map(\.uuidString))
        let before = entries.count
        entries = entries.filter { keys.contains($0.key) }
        if entries.count != before { persistLocked() }
    }

    // MARK: - Private

    private func mutate(_ itemID: UUID, _ body: (inout RescueLedgerEntry) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var entry = entries[itemID.uuidString] ?? RescueLedgerEntry()
        body(&entry)
        entries[itemID.uuidString] = entry
        persistLocked()
    }

    private func loadFromDisk() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder.rescueLedger.decode([String: RescueLedgerEntry].self, from: data)
        else { return }
        entries = decoded
    }

    private func persistLocked() {
        guard let fileURL, let data = try? JSONEncoder.rescueLedger.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var rescueLedger: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }
}
private extension JSONDecoder {
    static var rescueLedger: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
}

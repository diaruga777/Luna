//
//  SaveFailureStore.swift
//  LunaStorage
//

import Foundation
import LunaAppConfig
import LunaModels

/// What a failed save knows about itself beyond `state == .failed`: why it
/// failed, when, how many times, and the best title/site name Luna could
/// recover for a page it could never actually read.
///
/// Kept in a SIDECAR file, never on `ReadingListItem` — an older sibling app
/// decoding and re-encoding the shared `readingList.json` would silently drop
/// unknown keys and wipe it (the same reasoning as `RescueLedgerStore` and the
/// imageRefs / preloads sidecars).
public struct SaveFailureRecord: Codable, Equatable, Sendable {
    /// The coarse reason, straight off the ingest outcome.
    public var reason: SaveFailureReason?
    /// When the most recent attempt failed.
    public var lastFailureDate: Date
    /// How many times ingestion has ended `.failed` for this item — the retry
    /// sweep runs on every launch/foreground, so this climbs on its own.
    public var failureCount: Int
    /// A display title for a page that never yielded one: the site's real
    /// `<title>`/`og:title` when a light metadata read got through, else a
    /// slug-derived guess. Written by the card's metadata resolver, not by the
    /// pipeline.
    public var resolvedTitle: String?
    /// The publisher/site name (`og:site_name`, else the bare host).
    public var siteName: String?

    public init(reason: SaveFailureReason? = nil, lastFailureDate: Date = Date(),
                failureCount: Int = 1, resolvedTitle: String? = nil,
                siteName: String? = nil) {
        self.reason = reason
        self.lastFailureDate = lastFailureDate
        self.failureCount = failureCount
        self.resolvedTitle = resolvedTitle
        self.siteName = siteName
    }
}

/// App-Group-backed failure detail, written to `saveFailures.json` beside the
/// reading list. Cheap lock + atomic write (like `RescueLedgerStore`): the
/// records are display metadata, so a lost race costs a detail line, never a
/// save.
public final class SaveFailureStore {
    public static let shared = SaveFailureStore()

    private let fileURL: URL?
    private let now: () -> Date
    private let lock = NSLock()
    private var records: [String: SaveFailureRecord]   // key = item UUID string

    public init(containerURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.now = now
        let base = containerURL ?? FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupID)
        self.fileURL = base?.appendingPathComponent("saveFailures.json")
        self.records = [:]
        loadFromDisk()
    }

    public func record(for itemID: UUID) -> SaveFailureRecord? {
        lock.lock(); defer { lock.unlock() }
        return records[itemID.uuidString]
    }

    /// Records a fresh failure, bumping the count and refreshing the reason.
    /// A nil `reason` on a repeat failure keeps the previously captured one — a
    /// timeout on attempt two shouldn't erase attempt one's "403 blocked".
    public func recordFailure(_ itemID: UUID, reason: SaveFailureReason?) {
        mutate(itemID) { record in
            record.failureCount += 1
            record.lastFailureDate = self.now()
            if let reason { record.reason = reason }
        }
    }

    /// Stores the best title/site name a metadata read could recover, so the
    /// card shows the same words on the next cold launch without refetching.
    public func recordMetadata(_ itemID: UUID, title: String?, siteName: String?) {
        mutate(itemID) { record in
            if let title, !title.isEmpty { record.resolvedTitle = title }
            if let siteName, !siteName.isEmpty { record.siteName = siteName }
        }
    }

    /// Clears an item's record — called when it stops being failed (a rescue or
    /// a retry succeeded) so a later failure starts from a clean count.
    public func clear(_ itemID: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard records.removeValue(forKey: itemID.uuidString) != nil else { return }
        persistLocked()
    }

    /// Drops rows for items no longer present (called from the rescue sweep).
    public func prune(keeping ids: Set<UUID>) {
        lock.lock(); defer { lock.unlock() }
        let keys = Set(ids.map(\.uuidString))
        let before = records.count
        records = records.filter { keys.contains($0.key) }
        if records.count != before { persistLocked() }
    }

    // MARK: - Private

    private func mutate(_ itemID: UUID, _ body: (inout SaveFailureRecord) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var record = records[itemID.uuidString]
            ?? SaveFailureRecord(lastFailureDate: now(), failureCount: 0)
        body(&record)
        records[itemID.uuidString] = record
        persistLocked()
    }

    private func loadFromDisk() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder.saveFailures
                  .decode([String: SaveFailureRecord].self, from: data)
        else { return }
        records = decoded
    }

    private func persistLocked() {
        guard let fileURL, let data = try? JSONEncoder.saveFailures.encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var saveFailures: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }
}
private extension JSONDecoder {
    static var saveFailures: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
}

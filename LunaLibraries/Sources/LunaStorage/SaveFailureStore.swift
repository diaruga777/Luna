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
/// Kept in a SIDECAR file, never on `ReadingListItem` — failure detail belongs to
/// the layer that produced it rather than to the row four apps share (the same
/// reasoning as `RescueLedgerStore` and the preloads sidecar).
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
    /// The app version under which this item's Apple Intelligence rescue was
    /// spent and did not recover it (`AppConfig.appVersion`). Nil ⇒ the rescue
    /// has never been tried from the card.
    ///
    /// This is the failed card's **terminal gate**: one AI attempt per shipped
    /// version. While it equals the running version the card shows its apology
    /// and a Delete button instead of the button; an app update no longer
    /// matches, so the item becomes eligible again and the launch sweep retries
    /// it with both ordinary ingestion and AI. Storing the version rather than a
    /// bool is what makes that automatic — there's no migration step and no
    /// "clear all" pass to remember to run.
    public var aiAttemptVersion: String?

    public init(reason: SaveFailureReason? = nil, lastFailureDate: Date = Date(),
                failureCount: Int = 1, resolvedTitle: String? = nil,
                siteName: String? = nil, aiAttemptVersion: String? = nil) {
        self.reason = reason
        self.lastFailureDate = lastFailureDate
        self.failureCount = failureCount
        self.resolvedTitle = resolvedTitle
        self.siteName = siteName
        self.aiAttemptVersion = aiAttemptVersion
    }
}

/// App-Group-backed failure detail, written to `saveFailures.json` beside the
/// reading list. Every read and every mutation goes through the file: the share
/// and action extensions record failures while the app is suspended, so a
/// mutation applied to a snapshot from launch would drop whatever they wrote
/// (see `CoordinatedJSONFile`).
public final class SaveFailureStore {
    public static let shared = SaveFailureStore()

    private let now: () -> Date
    /// Keyed by item UUID string.
    private let file: CoordinatedJSONFile<[String: SaveFailureRecord]>

    public init(containerURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.now = now
        let base = containerURL ?? AppConfig.sharedContainerURL()
        self.file = CoordinatedJSONFile(
            url: base?.appendingPathComponent("saveFailures.json"),
            encoder: .sidecarISO8601, decoder: .sidecarISO8601, empty: { [:] })
    }

    public func record(for itemID: UUID) -> SaveFailureRecord? {
        file.read()[itemID.uuidString]
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

    /// Marks this item's one-per-version Apple Intelligence attempt as spent.
    /// Called when a card-initiated rescue finishes WITHOUT recovering the item;
    /// a success clears the whole record instead.
    public func recordAIAttempt(_ itemID: UUID, version: String = AppConfig.appVersion) {
        mutate(itemID) { record in record.aiAttemptVersion = version }
    }

    /// Whether the card should be terminal: an AI attempt was already spent
    /// under the version that's running now.
    public func hasSpentAIAttempt(
        _ itemID: UUID, version: String = AppConfig.appVersion
    ) -> Bool {
        record(for: itemID)?.aiAttemptVersion == version
    }

    /// Item IDs whose AI attempt was spent under some OTHER (older) version —
    /// the set an app update has just made eligible again. Read by the rescue
    /// coordinator at launch so it can clear their attempt budget.
    public func idsWithStaleAIAttempt(version: String = AppConfig.appVersion) -> Set<UUID> {
        Set(file.read().compactMap { key, record in
            guard let spent = record.aiAttemptVersion, spent != version else { return nil }
            return UUID(uuidString: key)
        })
    }

    /// Clears an item's record — called when it stops being failed (a rescue or
    /// a retry succeeded) so a later failure starts from a clean count.
    public func clear(_ itemID: UUID) {
        file.mutateIfChanged { records in
            (result: (), changed: records.removeValue(forKey: itemID.uuidString) != nil)
        }
    }

    /// Drops rows for items no longer present (called from the rescue sweep).
    public func prune(keeping ids: Set<UUID>) {
        let keys = Set(ids.map(\.uuidString))
        file.mutateIfChanged { records in
            let before = records.count
            records = records.filter { keys.contains($0.key) }
            return (result: (), changed: records.count != before)
        }
    }

    // MARK: - Private

    private func mutate(_ itemID: UUID, _ body: (inout SaveFailureRecord) -> Void) {
        file.mutate { records in
            var record = records[itemID.uuidString]
                ?? SaveFailureRecord(lastFailureDate: self.now(), failureCount: 0)
            body(&record)
            records[itemID.uuidString] = record
        }
    }
}

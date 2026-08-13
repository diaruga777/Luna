//
//  RescueLedgerStore.swift
//  LunaStorage
//

import Foundation
import LunaAppConfig
import LunaModels

/// Per-item rescue bookkeeping — how many automatic attempts an item has had,
/// when, whether one succeeded (provenance). Kept in a SIDECAR file, never on
/// `SavedItem`: the row every save has is read and rewritten by four
/// independently-updated apps, and bookkeeping only the rescue layer understands
/// has no business there. A sidecar only that layer touches keeps the hot shared
/// model untouched (same reasoning as the preloads sidecar).
public struct RescueLedgerEntry: Codable, Equatable {
    public var attemptCount: Int
    public var lastAttemptDate: Date?
    /// Provenance marker: this item was recovered by the rescue engine.
    public var succeeded: Bool
    public var lastHint: RescueHint?
    /// When a model guardrail (or a flat refusal) rejected this item's prompt.
    /// PERMANENT: the prompt is derived from the page, so the same page trips the
    /// same guardrail every time. Set, the coordinator never re-attempts the item
    /// — automatically or by tap — and the card stops offering a button that
    /// cannot work. Deliberately survives `resetAttempts(for:)`: a new app
    /// version changes Luna's extraction code, not Apple's safety model.
    public var guardrailedAt: Date?
    /// When this item was handed to the interactive archive-unlock tier. The
    /// deterministic `browserMayRecover` fast-path is once-only; a second handoff
    /// would just re-park a card the user already chose not to unlock.
    public var browserHandoffAt: Date?

    public init(attemptCount: Int = 0, lastAttemptDate: Date? = nil,
                succeeded: Bool = false, lastHint: RescueHint? = nil,
                guardrailedAt: Date? = nil, browserHandoffAt: Date? = nil) {
        self.attemptCount = attemptCount
        self.lastAttemptDate = lastAttemptDate
        self.succeeded = succeeded
        self.lastHint = lastHint
        self.guardrailedAt = guardrailedAt
        self.browserHandoffAt = browserHandoffAt
    }
}

/// App-Group-backed ledger, written to `rescueLedger.json` beside the reading
/// list. Every read and every mutation goes through the file (see
/// `CoordinatedJSONFile`), so a ledger row written from another process is not
/// rewritten away by this one's next attempt. "In-flight" is deliberately NOT
/// persisted (a crash must not strand an item) — the coordinator tracks that in
/// process memory.
public final class RescueLedgerStore {
    public static let shared = RescueLedgerStore()

    /// Automatic rescue budget: at most this many lifetime auto-attempts per item.
    public static let maxAutoAttempts = 2
    /// Minimum spacing between automatic attempts.
    public static let autoRetrySpacing: TimeInterval = 24 * 60 * 60

    private let now: () -> Date
    /// Keyed by item UUID string.
    private let file: CoordinatedJSONFile<[String: RescueLedgerEntry]>

    public init(containerURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.now = now
        let base = containerURL ?? AppConfig.sharedContainerURL()
        self.file = CoordinatedJSONFile(
            url: base?.appendingPathComponent("rescueLedger.json"),
            encoder: .sidecarISO8601, decoder: .sidecarISO8601, empty: { [:] })
    }

    /// Whether an automatic rescue is allowed for this item now — under the
    /// attempt cap and past the spacing window. Manual one-shots ignore this.
    public func shouldAutoRescue(_ itemID: UUID) -> Bool {
        guard let entry = file.read()[itemID.uuidString] else { return true }
        guard entry.guardrailedAt == nil else { return false }
        guard entry.attemptCount < Self.maxAutoAttempts else { return false }
        guard let last = entry.lastAttemptDate else { return true }
        return now().timeIntervalSince(last) >= Self.autoRetrySpacing
    }

    /// Whether this item is permanently out of rescue's reach. Checked by BOTH
    /// the automatic sweep and the manual tap — a guardrail is not a budget.
    public func isGuardrailed(_ itemID: UUID) -> Bool {
        file.read()[itemID.uuidString]?.guardrailedAt != nil
    }

    public func recordGuardrail(_ itemID: UUID) {
        mutate(itemID) { $0.guardrailedAt = self.now() }
    }

    /// Whether the interactive browser handoff has already been offered for this
    /// item — the once-only gate on the deterministic fast-path.
    public func hasHandedToBrowser(_ itemID: UUID) -> Bool {
        file.read()[itemID.uuidString]?.browserHandoffAt != nil
    }

    public func recordBrowserHandoff(_ itemID: UUID) {
        mutate(itemID) { $0.browserHandoffAt = self.now() }
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
        file.read()[itemID.uuidString]?.succeeded ?? false
    }

    public func entry(_ itemID: UUID) -> RescueLedgerEntry? {
        file.read()[itemID.uuidString]
    }

    /// Forgets these items' attempt history, so the automatic sweep may try them
    /// again immediately. Called once per app update for items whose Apple
    /// Intelligence attempt was spent under an older version: the extraction code
    /// has changed, so the 2-attempts/24h budget shouldn't hold a stale verdict.
    public func resetAttempts(for ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        file.mutateIfChanged { entries in
            var changed = false
            for id in ids {
                guard var entry = entries[id.uuidString], !entry.succeeded else { continue }
                entry.attemptCount = 0
                entry.lastAttemptDate = nil
                entries[id.uuidString] = entry
                changed = true
            }
            return (result: (), changed: changed)
        }
    }

    /// Drops ledger rows for items no longer present (called from the sweep).
    public func prune(keeping ids: Set<UUID>) {
        let keys = Set(ids.map(\.uuidString))
        file.mutateIfChanged { entries in
            let before = entries.count
            entries = entries.filter { keys.contains($0.key) }
            return (result: (), changed: entries.count != before)
        }
    }

    // MARK: - Private

    private func mutate(_ itemID: UUID, _ body: (inout RescueLedgerEntry) -> Void) {
        file.mutate { entries in
            var entry = entries[itemID.uuidString] ?? RescueLedgerEntry()
            body(&entry)
            entries[itemID.uuidString] = entry
        }
    }
}

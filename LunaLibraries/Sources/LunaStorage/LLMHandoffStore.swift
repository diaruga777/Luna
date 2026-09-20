//
//  LLMHandoffStore.swift
//  LunaStorage
//

import Foundation
import LunaAppConfig
import LunaModels

/// One hand-off in flight: Luna opened a provider with a prompt, and the
/// reply — a Luna file — has not come back yet
/// (`claudedocs/llm-handoff.md`).
public struct LLMHandoffRecord: Codable, Equatable, Sendable {

    /// What the model was asked for.
    public enum Kind: Codable, Equatable, Sendable {
        /// Recover one failed save. The item may be gone by the time the file
        /// arrives, so the URL travels beside its id.
        case recovery(itemID: UUID, urlString: String)
        /// Write a plugin. The user's own words are kept so the create screen
        /// still shows them after leaving and coming back.
        case plugin(description: String, host: String?)
    }

    public let id: UUID
    public let kind: Kind
    public let provider: LLMProvider
    public let claudeTarget: LLMClaudeTarget
    public let startedAt: Date
    /// Why the file that came back was refused, in one line for the card. A
    /// record with one is no longer waiting: the round trip finished, badly.
    public var refusal: String?
    public var refusedAt: Date?

    public init(
        id: UUID = UUID(), kind: Kind, provider: LLMProvider,
        claudeTarget: LLMClaudeTarget, startedAt: Date,
        refusal: String? = nil, refusedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.provider = provider
        self.claudeTarget = claudeTarget
        self.startedAt = startedAt
        self.refusal = refusal
        self.refusedAt = refusedAt
    }

    /// Whether the reply is still outstanding. A refused record stays on file so
    /// the card can say WHY after a relaunch, but it is not a wait any more.
    public var isWaiting: Bool { refusal == nil }

    /// The saved item this hand-off recovers, when it is a recovery.
    public var itemID: UUID? {
        if case .recovery(let itemID, _) = kind { return itemID }
        return nil
    }

    /// The page this hand-off recovers, when it is a recovery.
    public var urlString: String? {
        if case .recovery(_, let urlString) = kind { return urlString }
        return nil
    }
}

/// The hand-offs this device is waiting on, in `llmHandoffs.json` beside the
/// saves list.
///
/// App-Group backed because the two ends run in different processes: the share
/// extension's failure card can start a hand-off, and the app applies the file
/// that comes back. A record older than `lifetime` is gone — a user who never
/// pasted the reply has moved on, and a card waiting forever is a lie.
public final class LLMHandoffStore {
    public static let shared = LLMHandoffStore()

    /// How long a card keeps saying "waiting for the reply".
    public static let lifetime: TimeInterval = 24 * 60 * 60

    private let now: () -> Date
    /// Keyed by record id.
    private let file: CoordinatedJSONFile<[String: LLMHandoffRecord]>

    public init(containerURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.now = now
        let base = containerURL ?? AppConfig.sharedContainerURL()
        self.file = CoordinatedJSONFile(
            url: base?.appendingPathComponent("llmHandoffs.json"),
            encoder: .sidecarISO8601, decoder: .sidecarISO8601, empty: { [:] })
    }

    /// Records a hand-off that is about to open a provider, replacing whatever
    /// was recorded for the same target. Returns the record, whose id is how a
    /// caller clears it later.
    @discardableResult
    public func begin(
        _ kind: LLMHandoffRecord.Kind, provider: LLMProvider,
        claudeTarget: LLMClaudeTarget = LLMProviderPreferences.claudeTarget
    ) -> LLMHandoffRecord {
        let record = LLMHandoffRecord(
            kind: kind, provider: provider, claudeTarget: claudeTarget, startedAt: now())
        file.mutate { records in
            records = records.filter { !Self.isExpired($0.value, now: now()) }
            for (key, existing) in records where Self.sameTarget(existing.kind, kind) {
                records[key] = nil
            }
            records[record.id.uuidString] = record
        }
        return record
    }

    /// The live hand-off for a failed save, or nil.
    public func record(forItemID itemID: UUID) -> LLMHandoffRecord? {
        live().first { $0.itemID == itemID }
    }

    /// The live hand-off for a page, whichever item it belonged to. The file
    /// that comes back names the URL, not the id, and an item may have been
    /// re-added since.
    public func record(forURL urlString: String) -> LLMHandoffRecord? {
        live().first { $0.urlString == urlString }
    }

    /// Every live recovery hand-off. The applier reads them all because it
    /// matches a file's URL the way it matches a save's — host and path,
    /// normalized — rather than by the exact text the record was written with.
    public func recoveryRecords() -> [LLMHandoffRecord] {
        live().filter { $0.urlString != nil }
    }

    /// The live plugin hand-off — there is at most one, because a second
    /// request replaces the first.
    public func pluginRecord() -> LLMHandoffRecord? {
        live().first {
            if case .plugin = $0.kind { return true }
            return false
        }
    }

    /// Files the reason a Luna file for this hand-off was refused. It survives a
    /// relaunch, so the card explains itself on the next launch instead of
    /// quietly going back to the plain offer. The next provider tap replaces the
    /// record, and a successful apply clears it.
    public func markRefused(id: UUID, reason: String, now: Date? = nil) {
        let moment = now ?? self.now()
        file.mutateIfChanged { records in
            guard var record = records[id.uuidString] else {
                return (result: (), changed: false)
            }
            record.refusal = reason
            record.refusedAt = moment
            records[id.uuidString] = record
            return (result: (), changed: true)
        }
    }

    public func clear(id: UUID) {
        file.mutateIfChanged { records in
            (result: (), changed: records.removeValue(forKey: id.uuidString) != nil)
        }
    }

    /// Drops every record past its lifetime. Called where a surface is about
    /// to read the store, so an abandoned hand-off stops being shown.
    public func prune(now: Date? = nil) {
        let cutoff = now ?? self.now()
        file.mutateIfChanged { records in
            let before = records.count
            records = records.filter { !Self.isExpired($0.value, now: cutoff) }
            return (result: (), changed: records.count != before)
        }
    }

    // MARK: - Private

    private func live() -> [LLMHandoffRecord] {
        let moment = now()
        return file.read().values
            .filter { !Self.isExpired($0, now: moment) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private static func isExpired(_ record: LLMHandoffRecord, now: Date) -> Bool {
        now.timeIntervalSince(record.startedAt) >= lifetime
    }

    /// Two hand-offs for the same save, or two plugin requests, are the same
    /// target: the newer one replaces the older rather than queueing behind it.
    private static func sameTarget(
        _ lhs: LLMHandoffRecord.Kind, _ rhs: LLMHandoffRecord.Kind
    ) -> Bool {
        switch (lhs, rhs) {
        case let (.recovery(_, left), .recovery(_, right)): return left == right
        case (.plugin, .plugin): return true
        default: return false
        }
    }
}

//
//  RescueStatsStore.swift
//  LunaStorage
//

import Foundation
import LunaAppConfig

/// Aggregate rescue counters — how many attempts ran, how they ended, and which
/// method recovered the ones that worked.
///
/// The feature had NO measurement of any kind: the only durable record was the
/// per-item ledger, pruned the moment an item disappeared, so "I've yet to see
/// it accomplish anything" was neither confirmable nor refutable. These are
/// counts, not events: nothing here identifies an item, a URL or a host, so the
/// file survives item deletion and carries nothing worth protecting.
///
/// Sidecar, never `readingList.json` — same reasoning as `RescueLedgerStore`.
public struct RescueStats: Codable, Equatable {
    /// Attempts that reached the engine (a cached-rule replay counts).
    public var attempts: Int
    /// Outcome tallies, keyed by `RescueStatsOutcome.rawValue`.
    public var outcomes: [String: Int]
    /// Successful-method tallies, keyed by `RescueMethod.rawValue` as the engine
    /// spells it. A raw string rather than an enum so LunaStorage does not have
    /// to depend on the rescue module that owns that enum.
    public var methods: [String: Int]
    /// Attempts a learned per-host rule answered before any model call.
    public var cachedRuleHits: Int

    public init(attempts: Int = 0, outcomes: [String: Int] = [:],
                methods: [String: Int] = [:], cachedRuleHits: Int = 0) {
        self.attempts = attempts
        self.outcomes = outcomes
        self.methods = methods
        self.cachedRuleHits = cachedRuleHits
    }

    public func outcome(_ outcome: RescueStatsOutcome) -> Int { outcomes[outcome.rawValue] ?? 0 }

    /// "reroute 3, search 1" — the method breakdown for the diagnostics line.
    /// Raw method tokens on purpose: this screen is a developer surface, and a
    /// translated method name would be a worse label, not a better one.
    public var methodSummary: String {
        methods.filter { $0.value > 0 }
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { "\($0.key) \($0.value)" }
            .joined(separator: ", ")
    }
}

/// The coarse buckets a rescue attempt can land in. Deliberately not a mirror of
/// `RescueOutcome` (which carries payloads): these are the questions worth
/// asking of a running install.
public enum RescueStatsOutcome: String, CaseIterable, Sendable {
    case rescued
    case browserHandoff
    case unrescuable
    case guardrailed
    case modelError
    case modelUnavailable
    case surfaceDropped
    case timedOut
}

/// App-Group-backed counters in `rescueStats.json`, same lock + atomic-write
/// shape as `SaveFailureStore`.
public final class RescueStatsStore: @unchecked Sendable {
    public static let shared = RescueStatsStore()

    private let fileURL: URL?
    private let lock = NSLock()
    private var stats: RescueStats

    public init(containerURL: URL? = nil) {
        let base = containerURL ?? AppConfig.sharedContainerURL()
        self.fileURL = base?.appendingPathComponent("rescueStats.json")
        self.stats = RescueStats()
        loadFromDisk()
    }

    public func snapshot() -> RescueStats {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    public func recordAttempt() {
        mutate { $0.attempts += 1 }
    }

    public func recordCachedRuleHit() {
        mutate { $0.cachedRuleHits += 1 }
    }

    /// One terminal verdict per attempt. `method` is set only for the outcomes
    /// that recovered something.
    public func record(_ outcome: RescueStatsOutcome, method: String? = nil) {
        mutate { stats in
            stats.outcomes[outcome.rawValue, default: 0] += 1
            if let method { stats.methods[method, default: 0] += 1 }
        }
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        stats = RescueStats()
        persistLocked()
    }

    /// The `[rescue]` line a sweep logs, and the same numbers the Diagnostics
    /// screen shows. Plain ASCII, safe for the shared log.
    public func summaryLine() -> String {
        let stats = snapshot()
        var parts = ["attempts=\(stats.attempts)"]
        for outcome in RescueStatsOutcome.allCases where stats.outcome(outcome) > 0 {
            parts.append("\(outcome.rawValue)=\(stats.outcome(outcome))")
        }
        if stats.cachedRuleHits > 0 { parts.append("cachedRule=\(stats.cachedRuleHits)") }
        let methods = stats.methodSummary
        if !methods.isEmpty { parts.append("by(\(methods))") }
        return parts.joined(separator: " ")
    }

    // MARK: - Private

    private func mutate(_ body: (inout RescueStats) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&stats)
        persistLocked()
    }

    private func loadFromDisk() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(RescueStats.self, from: data)
        else { return }
        stats = decoded
    }

    private func persistLocked() {
        guard let fileURL, let data = try? JSONEncoder().encode(stats) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

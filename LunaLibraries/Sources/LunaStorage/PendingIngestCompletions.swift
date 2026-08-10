//
//  PendingIngestCompletions.swift
//  LunaStorage
//

import Foundation
import LunaAppConfig

/// One reserved reading-list row that still owes its metadata pass.
public struct PendingIngestCompletion: Codable, Equatable, Sendable {
    public let itemID: UUID
    public let urlString: String
    public let dateOwed: Date
    /// How many background attempts this row has already cost. Never a reason to
    /// give up (see `PendingIngestCompletions`); it exists so the diagnostic log
    /// can say a resume was a retry rather than a first pass.
    public var attempts: Int

    public init(itemID: UUID, urlString: String, dateOwed: Date, attempts: Int = 0) {
        self.itemID = itemID
        self.urlString = urlString
        self.dateOwed = dateOwed
        self.attempts = attempts
    }
}

extension Notification.Name {
    /// "There is owed ingest work and now is a good moment to run it." Posted by
    /// `PendingIngestCompletions.requestRun()`; the app observes it through
    /// `BackgroundIngestCompletion.install()` (LunaReadingList — the tier that
    /// can actually name the ingestor). A process with no observer, an
    /// extension for instance, simply owes the work to the next app launch.
    public static let pendingIngestCompletionsRequested =
        Notification.Name("Luna.pendingIngestCompletionsRequested")
}

/// The rows a fast surface RESERVED but had no time to ingest.
///
/// Safari's Download hand-off is the one that needs this: the app is launched
/// only to persist the save, start the transfer and request the Live Activity,
/// and then it hands the user straight back to the page (`claudedocs/
/// safari-extension.md`). The row it reserved is `.pending` with no title, no
/// thumbnail and no kind — and waiting for the user to happen to open the app
/// again is exactly the "incomplete item sitting in the deck" this queue exists
/// to prevent.
///
/// It is a QUEUE and not merely the `.pending` rows themselves because the two
/// answer different questions: `.pending` says "unfinished", while an entry here
/// says "unfinished AND nobody is going to look at it — finish it in the
/// background". That is what lets a resume (a background `URLSession` waking the
/// process, a launch) do exactly the owed work under a lease instead of
/// re-sweeping the whole store.
///
/// Take-semantics are deliberately NOT used: an entry is settled only once the
/// row actually left `.pending`, so a run interrupted by an expiring background
/// window leaves the debt behind rather than losing it. Modeled on
/// `PendingResolvedMediaStore` (App-Group defaults, 3-day lifetime), which is
/// the queue that feeds it.
public final class PendingIngestCompletions {
    public static let shared = PendingIngestCompletions()

    /// Same as the resolved-media queue that produces these: a hand-off the user
    /// abandoned until the next morning must still land. Past it the row is
    /// still `.pending`, so the ordinary `ingestAllPending` sweep — the safety
    /// net for a process that was killed — remains its backstop.
    public static let lifetime: TimeInterval = 3 * 24 * 60 * 60

    private static let key = "ingest.pendingCompletions"

    private let defaults: UserDefaults
    private let now: () -> Date
    private let lock = NSLock()

    public init(defaults: UserDefaults? = nil, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults ?? UserDefaults(suiteName: AppConfig.appGroupID) ?? .standard
        self.now = now
    }

    /// Records that `itemID`'s ingest is owed. Idempotent per row: a second
    /// hand-off for the same save keeps the original debt (and its attempt
    /// count) rather than resetting it.
    public func owe(itemID: UUID, urlString: String) {
        lock.lock(); defer { lock.unlock() }
        var current = loadLocked()
        guard !current.contains(where: { $0.itemID == itemID }) else { return }
        current.append(PendingIngestCompletion(
            itemID: itemID, urlString: urlString, dateOwed: now()))
        saveLocked(current)
    }

    /// Everything still owed, oldest first. Expired entries are dropped in
    /// passing — and LOGGED, because a debt that quietly disappears is exactly
    /// the failure mode this queue exists to rule out.
    public func owed() -> [PendingIngestCompletion] {
        lock.lock(); defer { lock.unlock() }
        let all = loadLocked()
        let fresh = all.filter { now().timeIntervalSince($0.dateOwed) < Self.lifetime }
        if fresh.count != all.count {
            for expired in all where !fresh.contains(expired) {
                SharedDiagnosticLog.record(
                    "background ingest debt expired unfinished for \(expired.urlString) "
                        + "after \(expired.attempts) attempt(s) — the pending sweep owns it now",
                    category: "ingest")
            }
            saveLocked(fresh)
        }
        return fresh
    }

    /// Marks that a background attempt is starting for `itemID`.
    public func recordAttempt(_ itemID: UUID) {
        lock.lock(); defer { lock.unlock() }
        var current = loadLocked()
        guard let index = current.firstIndex(where: { $0.itemID == itemID }) else { return }
        current[index].attempts += 1
        saveLocked(current)
    }

    /// The row reached a verdict (ready, failed, dropped, gone) — nothing more is
    /// owed for it.
    public func settle(_ itemID: UUID) {
        lock.lock(); defer { lock.unlock() }
        let current = loadLocked()
        let remaining = current.filter { $0.itemID != itemID }
        guard remaining.count != current.count else { return }
        saveLocked(remaining)
    }

    /// "Now is a good moment to work the queue" — posted after the hand-off has
    /// already sent the user back to Safari, and at every resume point that can
    /// reach a backgrounded app (see `BackgroundIngestCompletion`).
    public func requestRun() {
        NotificationCenter.default.post(
            name: .pendingIngestCompletionsRequested, object: nil)
    }

    private func loadLocked() -> [PendingIngestCompletion] {
        guard let data = defaults.data(forKey: Self.key),
              let all = try? JSONDecoder().decode([PendingIngestCompletion].self, from: data)
        else { return [] }
        return all
    }

    private func saveLocked(_ entries: [PendingIngestCompletion]) {
        guard !entries.isEmpty else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

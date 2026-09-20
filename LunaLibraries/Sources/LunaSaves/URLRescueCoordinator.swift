//
//  URLRescueCoordinator.swift
//  LunaSaves
//

import Foundation
import LunaModels
import LunaStorage

/// The app-shell-installed bridge to the `LunaURLRescue` engine + persistence.
/// Left uninstalled ⇒ rescue is inert (extensions, tests, or the engine
/// unavailable).
public protocol URLRescueEngineBridging {
    /// Cheap "is a model usable" gate; the sweep and the inline trigger both
    /// stand down when it is false.
    var isRescueAvailable: Bool { get }
    /// Runs the item's one rescue. The conformer itself applies the outcome and
    /// persists.
    func performRescue(for item: SavedItem) async -> URLRescueCoordinator.RescueRunResult
}

/// Drives URL rescue for the main app: an inline attempt when a save fails, a
/// debounced background sweep of `.failed` items, and the extension→app
/// pending-request hand-off. Every route is the same budgeted funnel — one
/// automatic attempt per item, and no surface offers a second
/// (`claudedocs/url-rescue.md`). The debounced
/// `.savesChanged` sweep + foreground tracking is `SavesSweepDriver`
/// (shared with `AudioScriptPipeline`); this class keeps its own NSLock'd
/// in-flight set.
///
/// The rescue engine lives in `LunaURLRescue`, which this module must not
/// link — it is main-app-only. The app shell (`URLRescueWiring`) injects it
/// as `engine` and does the actual work. This coordinator only decides when,
/// tracks bookkeeping, and posts `.savesChanged` so rows refresh.
public final class URLRescueCoordinator {
    public static let shared = URLRescueCoordinator()

    /// How one rescue attempt ended, as much as this module needs to know.
    /// The three not-recovered endings stay distinct because the ledger treats
    /// them differently: a guardrail closes the item for good, while a model
    /// that never got to look leaves the sweep free to try again.
    public enum RescueRunResult: Equatable {
        /// The item left `.failed` — content recovered, media downloading, or
        /// handed to the interactive unlock tier.
        case advanced
        /// The model looked and could not recover it.
        case notRecovered
        /// The model never really answered — assets unavailable, another request
        /// holding the session, no model at all, a quota wall. Must not spend the
        /// per-version attempt.
        case transient
        /// A content-safety guardrail (or a flat refusal) rejected the
        /// prompt. This is permanent for this item, since the prompt is
        /// derived from the page.
        case guardrailed
        /// The rescue did recover content, but this app's surface does not
        /// show that kind, so the save was dropped on the way in. Not the
        /// user's attempt to lose.
        case surfaceDropped
    }

    /// The bridge installed by the app shell, or nil ⇒ rescue is inert
    /// (extensions, tests, or the engine unavailable).
    public static var engine: (any URLRescueEngineBridging)?

    private let store: SavesStore
    private let ledger: RescueLedgerStore
    private let pending: PendingRescueRequestStore
    private let stats: RescueStatsStore
    private let debounceInterval: TimeInterval
    private let now: () -> Date
    /// Owns the debounce scheduling + foreground tracking; `runSweep()` (this
    /// class's own reentrancy-guarded sweep body) and `isForeground` stay here.
    /// A foreground transition also drains queued extension→app hand-offs,
    /// exactly as it did before the scheduling moved into the shared driver.
    private lazy var sweepDriver = SavesSweepDriver(
        queueLabel: "com.hsanabria.luna.urlRescueCoordinator",
        debounceInterval: debounceInterval,
        sweeper: self)

    private var installed = false
    private var isSweeping = false
    private var isForeground = true
    private let inFlightLock = NSLock()
    private var inFlightItemIDs: Set<UUID> = []
    /// The most recent stage reported for each in-flight rescue, with the time it
    /// was reported. Process-local and never persisted: the eclipse bar on a
    /// failed card reads it, and it dies with the attempt.
    private var stages: [UUID: (stage: RescueStage, at: Date)] = [:]

    /// Max items rescued per sweep pass (serialized, so this bounds concurrent LLM use).
    public static let sweepBatchLimit = 3

    public init(
        store: SavesStore = .shared,
        ledger: RescueLedgerStore = .shared,
        pending: PendingRescueRequestStore = .shared,
        stats: RescueStatsStore = .shared,
        debounceInterval: TimeInterval = 1.5,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.ledger = ledger
        self.pending = pending
        self.stats = stats
        self.debounceInterval = debounceInterval
        self.now = now
    }

    // MARK: - Install

    /// Idempotent. Observes `.savesChanged` (debounced) + foreground/
    /// background, runs a launch sweep, and drains pending hand-offs. Only the
    /// main app calls this (extensions never do).
    public func install() {
        guard !installed else { return }
        installed = true
        sweepDriver.install()
        drainPendingRequests()
    }

    // MARK: - Inline trigger (from SavesIngestor)

    /// Called when a first-pass ingest ended `.failed`. Runs the item's one
    /// automatic rescue straight away, whoever the caller is: the sweep would
    /// only pick the item up a moment later, and an item rescued here never
    /// waits for it. Never blocks the caller.
    public func itemJustFailed(_ itemID: UUID, source: CaptureSource) {
        guard let engine = Self.engine, engine.isRescueAvailable else { return }
        guard ledger.shouldAutoRescue(itemID) else { return }
        Task { [weak self] in await self?.runRescue(itemID: itemID) }
    }

    /// Whether `itemID` is being rescued right now (for the "trying harder…" row).
    public func isRescuing(_ itemID: UUID) -> Bool {
        inFlightLock.lock(); defer { inFlightLock.unlock() }
        return inFlightItemIDs.contains(itemID)
    }

    // MARK: - Progress

    /// Called by the app shell's engine bridge as the rescue crosses each
    /// stage. Cheap and lock-scoped: it stores the stage and posts
    /// `.rescueProgressChanged` for the one card that cares, not
    /// `.savesChanged`, which would reload every deck several times per
    /// rescue.
    public func reportProgress(_ itemID: UUID, stage: RescueStage) {
        inFlightLock.lock()
        stages[itemID] = (stage, now())
        inFlightLock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .rescueProgressChanged, object: nil,
                userInfo: [RescueProgressKey.itemID: itemID])
        }
    }

    /// How far along `itemID`'s rescue is, 0…1, or nil when nothing is running.
    ///
    /// Interpolates from the last reported stage toward the next one using that
    /// stage's expected duration, so the bar keeps creeping through a 22-second
    /// model call instead of freezing. It never reaches the next stage's fraction
    /// on interpolation alone — only a real stage report gets it there.
    public func rescueProgress(_ itemID: UUID) -> Double? {
        inFlightLock.lock(); defer { inFlightLock.unlock() }
        guard let entry = stages[itemID] else { return nil }
        let start = entry.stage.fraction
        guard let next = Self.stageAfter(entry.stage) else { return start }
        let duration = entry.stage.expectedDuration
        guard duration > 0 else { return start }
        let elapsed = max(0, now().timeIntervalSince(entry.at))
        // Ease out: 63% of the gap by the expected duration, asymptotic after —
        // an overrunning stage slows down rather than stalling or overshooting.
        let eased = 1 - exp(-elapsed / duration)
        return start + (next.fraction - start) * eased * 0.9
    }

    private static func stageAfter(_ stage: RescueStage) -> RescueStage? {
        // The article-payload stage is skipped on every non-PCC path, so the
        // stage list is walked in declaration order rather than assuming each
        // stage is followed by the next one that actually ran.
        guard let index = RescueStage.allCases.firstIndex(of: stage),
              index + 1 < RescueStage.allCases.count else { return nil }
        return RescueStage.allCases[index + 1]
    }

    // MARK: - Pending hand-off drain

    /// Consumes queued extension→app rescue requests: finds (or re-adds) the
    /// item and runs the same budgeted rescue every other trigger runs. The
    /// extension queues one for every failure it sees, so this is the automatic
    /// attempt for a save that failed while the app was not running. Idempotent;
    /// safe to call from launch, foreground, and the `<scheme>://rescue` deep
    /// link.
    public func drainPendingRequests() {
        let requests = pending.takeAll()
        guard !requests.isEmpty else { return }
        for request in requests {
            let itemID: UUID
            if let existing = store.item(forURLString: request.urlString) {
                itemID = existing.id
            } else if let added = store.addIfAbsent(urlString: request.urlString, source: .shareSheet) {
                itemID = added.id
            } else {
                continue
            }
            guard ledger.shouldAutoRescue(itemID) else { continue }
            Task { [weak self] in await self?.runRescue(itemID: itemID) }
        }
    }

    // MARK: - Sweep

    private func runSweep() {
        guard let engine = Self.engine, engine.isRescueAvailable else { return }
        guard isForeground, !isSweeping else { return }
        isSweeping = true
        defer { isSweeping = false }

        let ingestor = SavesIngestor.shared
        var launched = 0
        for item in store.items() {
            guard launched < Self.sweepBatchLimit else { break }
            guard item.state == .failed else { continue }
            guard ledger.shouldAutoRescue(item.id), !isRescuing(item.id), !ingestor.isIngesting(item.id) else { continue }
            launched += 1
            let id = item.id
            Task { [weak self] in await self?.runRescue(itemID: id) }
        }
        // Opportunistic cleanup of ledger rows for items no longer present.
        ledger.prune(keeping: Set(store.items().map(\.id)))

        // One aggregate line per sweep that actually did something. Rescue had no
        // measurement of any kind before this: the per-item ledger is pruned the
        // moment an item disappears, so "it never accomplishes anything" was
        // neither confirmable nor refutable from a shared log.
        if launched > 0 {
            SharedDiagnosticLog.record(
                "sweep launched=\(launched) \(stats.summaryLine())", category: "rescue")
        }
    }

    // MARK: - Run

    /// The one funnel every trigger runs through: it re-reads the item, spends
    /// the ledger attempt, and records what the engine concluded.
    @discardableResult
    private func runRescue(itemID: UUID) async -> RescueRunResult {
        guard let engine = Self.engine else { return .notRecovered }
        // Re-reads: the item may have advanced or been deleted since it was
        // scheduled. This rescues anything not yet ready — the "only .failed"
        // gating is enforced at the call sites — since a drained hand-off may
        // target a still-`.pending` item.
        guard let item = store.item(withID: itemID), item.state != .ready else { return .notRecovered }
        guard beginInFlight(itemID) else { return .notRecovered }
        defer {
            endInFlight(itemID)
            postSavesChanged()
        }

        ledger.recordAttempt(itemID)
        postSavesChanged() // Flips the row to "trying harder…".

        let result = await engine.performRescue(for: item)
        switch result {
        case .advanced:
            ledger.recordSuccess(itemID)
        case .guardrailed:
            // Permanent, and the ledger is what makes it permanent: no sweep
            // and no tap will reach this item again, so nothing is gained by
            // also marking the version attempt spent.
            ledger.recordGuardrail(itemID)
        case .notRecovered, .transient, .surfaceDropped:
            // The attempt is spent either way. What the user does next is the
            // chat hand-off the failed card offers, not another model call.
            break
        }
        return result
    }

    /// `.savesChanged` is a UI-refresh notification, and its list/deck
    /// observers are selector-based — so they run on whatever thread posted, and
    /// then touch UIKit. `runRescue` runs on a task executor, not the main actor,
    /// so hop first (the same thing `SavesStore.postChanged` does for every
    /// store mutation; these two posts were the only ones that didn't).
    private func postSavesChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .savesChanged, object: nil)
        }
    }

    // MARK: - In-flight bookkeeping (process-local, never persisted)

    private func beginInFlight(_ id: UUID) -> Bool {
        inFlightLock.lock(); defer { inFlightLock.unlock() }
        guard !inFlightItemIDs.contains(id) else { return false }
        inFlightItemIDs.insert(id)
        return true
    }

    private func endInFlight(_ id: UUID) {
        inFlightLock.lock(); defer { inFlightLock.unlock() }
        inFlightItemIDs.remove(id)
        stages[id] = nil
    }
}

/// The sweep body and the foreground tracking `SavesSweepDriver` drives.
/// Only the scheduling lives in the driver; the reentrancy guard is this class's
/// own, and a foreground transition also drains queued extension→app hand-offs.
extension URLRescueCoordinator: SavesSweepForegroundTracking {
    public func runSavesSweep() { runSweep() }

    public func savesSweepForegroundChanged(to isForeground: Bool) {
        self.isForeground = isForeground
        if isForeground { drainPendingRequests() }
    }
}

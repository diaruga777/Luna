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
    /// Cheap "is a model usable" gate; drives whether affordances appear.
    var isRescueAvailable: Bool { get }
    /// Runs a rescue for `item` with `hint`; `interactive` picks the budget. The
    /// conformer itself applies the outcome and persists.
    func performRescue(
        for item: SavedItem, hint: RescueHint?, interactive: Bool
    ) async -> URLRescueCoordinator.RescueRunResult
}

/// Drives URL rescue for the main app: an inline attempt when a foreground save
/// fails, a debounced background sweep of `.failed` items, one-shot manual
/// rescues, and the extension→app pending-request hand-off. The debounced
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
    /// The three not-recovered endings are distinct, and only one should
    /// spend the user's one visible attempt: a real verdict on the page
    /// spends it, a model that never got to look should not, and a safety
    /// guardrail should never be asked again.
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
    private let failures: SaveFailureStore
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
        failures: SaveFailureStore = .shared,
        stats: RescueStatsStore = .shared,
        debounceInterval: TimeInterval = 1.5,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.ledger = ledger
        self.pending = pending
        self.failures = failures
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
        reopenStaleVersionAttempts()
        drainPendingRequests()
    }

    /// One free retry per shipped version. A failed save whose Apple
    /// Intelligence attempt was spent under an earlier version has its
    /// ledger budget cleared here, so this launch's sweep tries it again.
    /// Because `SavesIngestor.ingestAllPending` already re-runs ordinary
    /// ingestion for every `.failed` item on launch, the item gets both
    /// paths without any extra scheduling.
    ///
    /// Nothing needs to clear `aiAttemptVersion` itself: the card compares it to
    /// the running version, so an update makes every stale mark non-terminal at
    /// once, and a fresh failure under this version overwrites it.
    @discardableResult
    public func reopenStaleVersionAttempts() -> Set<UUID> {
        let stale = failures.idsWithStaleAIAttempt()
        guard !stale.isEmpty else { return [] }
        ledger.resetAttempts(for: stale)
        return stale
    }

    // MARK: - Inline trigger (from SavesIngestor)

    /// Called when a first-pass ingest ended `.failed`. Re-reads the item
    /// and, if it is still `.failed` and eligible, runs an inline,
    /// interactive rescue, or leaves it for the background sweep. Never
    /// blocks the caller.
    public func itemJustFailed(_ itemID: UUID, source: CaptureSource, interactive: Bool) {
        guard let engine = Self.engine, engine.isRescueAvailable else { return }
        guard interactive, ledger.shouldAutoRescue(itemID) else {
            // Non-interactive failures (background sweeps, extension saves) are
            // picked up by the debounced sweep, not rescued inline.
            return
        }
        Task { [weak self] in await self?.runRescue(itemID: itemID, hint: nil, interactive: true, countsAgainstBudget: true) }
    }

    /// A user-consented one-shot rescue (the failed card's button, a
    /// failed-row tap, the extension hand-off). Bypasses the auto-attempt
    /// budget — the tap is itself consent — and spends the item's one Apple
    /// Intelligence attempt for this app version, so a card that comes back
    /// still failed goes terminal.
    public func requestManualRescue(itemID: UUID, hint: RescueHint?) {
        guard let engine = Self.engine, engine.isRescueAvailable else { return }
        // A guardrailed item is permanently out of reach; the tap must not spend
        // 90 seconds re-proving it. The card doesn't offer the button either
        // (`FailedSaveCardFactory.rescueState`), so this is belt-and-braces for
        // the other entry points (the deep-link drain, a stale row menu).
        guard !ledger.isGuardrailed(itemID) else { return }
        Task { [weak self] in
            await self?.runRescue(
                itemID: itemID, hint: hint, interactive: true,
                countsAgainstBudget: false, spendsVersionAttempt: true)
        }
    }

    /// The same consented one-shot rescue as `requestManualRescue`, but
    /// awaited, and reporting whether the item recovered.
    ///
    /// For the bulk file import (`claudedocs/import-export.md`), which cannot use
    /// the fire-and-forget form: it has to know each item's fate before it can
    /// score the run, and its progress bar has to hold the item's slice open
    /// until the rescue is really finished. Consent is the Import button, so the
    /// auto-attempt budget is bypassed exactly as it is for a tap on a failed
    /// card, and the version attempt is spent the same way — a link the model
    /// couldn't recover during an import doesn't get asked again until the next
    /// app update.
    ///
    /// Returns false when rescue is unavailable, so the caller reports an
    /// ordinary failure rather than pretending an attempt happened.
    @discardableResult
    public func rescueAndWait(itemID: UUID, hint: RescueHint? = nil) async -> Bool {
        guard let engine = Self.engine, engine.isRescueAvailable else { return false }
        guard !ledger.isGuardrailed(itemID) else { return false }
        return await runRescue(
            itemID: itemID, hint: hint, interactive: true,
            countsAgainstBudget: false, spendsVersionAttempt: true) == .advanced
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

    /// Consumes queued extension→app rescue requests: finds (or re-adds) the item
    /// and kicks a manual rescue with the requested hint. Idempotent; safe to call
    /// from launch, foreground, and the `<scheme>://rescue` deep link.
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
            requestManualRescue(itemID: itemID, hint: request.hint)
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
            Task { [weak self] in await self?.runRescue(itemID: id, hint: nil, interactive: false, countsAgainstBudget: true) }
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

    /// Returns whether the item advanced. Every early return is a false: the
    /// awaited caller (`rescueAndWait`) must not read "nothing to do" as success.
    @discardableResult
    private func runRescue(
        itemID: UUID, hint: RescueHint?, interactive: Bool,
        countsAgainstBudget: Bool, spendsVersionAttempt: Bool = false
    ) async -> RescueRunResult {
        guard let engine = Self.engine else { return .notRecovered }
        // Re-reads: the item may have advanced or been deleted since it was
        // scheduled. This rescues anything not yet ready — the "only
        // .failed" gating for automatic rescue is enforced at the call
        // sites (itemJustFailed, the sweep) — since a manual or drained
        // request may target a still-`.pending` item.
        guard let item = store.item(withID: itemID), item.state != .ready else { return .notRecovered }
        guard beginInFlight(itemID) else { return .notRecovered }
        defer {
            endInFlight(itemID)
            postSavesChanged()
        }

        if countsAgainstBudget { ledger.recordAttempt(itemID, hint: hint) }
        postSavesChanged() // Flips the row to "trying harder…".

        let result = await engine.performRescue(for: item, hint: hint, interactive: interactive)
        switch result {
        case .advanced:
            ledger.recordSuccess(itemID, hint: hint)
        case .guardrailed:
            // Permanent, and the ledger is what makes it permanent: no sweep
            // and no tap will reach this item again, so nothing is gained by
            // also marking the version attempt spent.
            ledger.recordGuardrail(itemID)
        case .notRecovered:
            if spendsVersionAttempt {
                // The user asked for AI, and AI did not recover it. This
                // records which version spent the attempt, so the card can
                // say so plainly now and offer itself again after the next
                // update.
                failures.recordAIAttempt(itemID)
            }
        case .transient, .surfaceDropped:
            // Either the model never saw the page, or it did recover the
            // content and this app's surface dropped it. Neither is a
            // verdict the user's one visible attempt should pay for.
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

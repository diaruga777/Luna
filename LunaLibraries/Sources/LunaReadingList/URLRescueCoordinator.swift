//
//  URLRescueCoordinator.swift
//  LunaReadingList
//

import Foundation
import LunaModels
import LunaStorage
#if canImport(UIKit)
import UIKit
#endif

/// Drives URL rescue for the main app: an inline attempt when a foreground save
/// fails, a debounced background sweep of `.failed` items, one-shot manual
/// rescues, and the extension→app pending-request hand-off. Modeled on
/// `AudioScriptPipeline` (debounced `.readingListChanged` + foreground tracking +
/// an NSLock'd in-flight set).
///
/// The rescue ENGINE lives in `LunaURLRescue`, which this module must not link
/// (it's main-app-only). The app shell (`URLRescueWiring`) injects it as `engine`
/// and does the actual work — this coordinator only decides WHEN, tracks
/// bookkeeping, and posts `.readingListChanged` so rows refresh.
public final class URLRescueCoordinator {
    public static let shared = URLRescueCoordinator()

    /// The app-shell-installed bridge to the `LunaURLRescue` engine + persistence.
    /// nil ⇒ rescue is inert (extensions, tests, or the engine unavailable).
    public struct Engine {
        /// Cheap "is a model usable" gate; drives whether affordances appear.
        public var isAvailable: () -> Bool
        /// Runs a rescue for `item` with `hint`; `interactive` picks the budget.
        /// Returns true when the item advanced (ready /
        /// tracker / media). The closure itself records the ledger + persists.
        public var perform: (ReadingListItem, RescueHint?, _ interactive: Bool) async -> Bool

        public init(isAvailable: @escaping () -> Bool,
                    perform: @escaping (ReadingListItem, RescueHint?, _ interactive: Bool) async -> Bool) {
            self.isAvailable = isAvailable
            self.perform = perform
        }
    }

    public static var engine: Engine?

    private let store: ReadingListStore
    private let ledger: RescueLedgerStore
    private let pending: PendingRescueRequestStore
    private let failures: SaveFailureStore
    private let debounceInterval: TimeInterval
    private let now: () -> Date
    private let workQueue = DispatchQueue(label: "com.hsanabria.luna.urlRescueCoordinator", qos: .utility)

    private var installed = false
    private var debounceWorkItem: DispatchWorkItem?
    private var isSweeping = false
    private var isForeground = true
    private let inFlightLock = NSLock()
    private var inFlightItemIDs: Set<UUID> = []
    /// The most recent stage reported for each in-flight rescue, with the time it
    /// was reported. Process-local and never persisted: the eclipse bar on a
    /// failed card reads it, and it dies with the attempt.
    private var stages: [UUID: (stage: RescueStage, at: Date)] = [:]

    private var notificationObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?

    /// Max items rescued per sweep pass (serialized, so this bounds concurrent LLM use).
    public static let sweepBatchLimit = 3

    public init(
        store: ReadingListStore = .shared,
        ledger: RescueLedgerStore = .shared,
        pending: PendingRescueRequestStore = .shared,
        failures: SaveFailureStore = .shared,
        debounceInterval: TimeInterval = 1.5,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.ledger = ledger
        self.pending = pending
        self.failures = failures
        self.debounceInterval = debounceInterval
        self.now = now
    }

    deinit {
        [notificationObserver, foregroundObserver, backgroundObserver]
            .compactMap { $0 }
            .forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Install

    /// Idempotent. Observes `.readingListChanged` (debounced) + foreground/
    /// background, runs a launch sweep, and drains pending hand-offs. Only the
    /// main app calls this (extensions never do).
    public func install() {
        guard !installed else { return }
        installed = true
        #if canImport(UIKit)
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .readingListChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleSweep(debounced: true) }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.isForeground = true
            self?.drainPendingRequests()
            self?.scheduleSweep(debounced: false)
        }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.isForeground = false }
        #endif
        reopenStaleVersionAttempts()
        drainPendingRequests()
        scheduleSweep(debounced: false)
    }

    /// One free retry per shipped version. A failed save whose Apple Intelligence
    /// attempt was spent under an EARLIER version has its ledger budget cleared
    /// here, so this launch's sweep tries it again — and because
    /// `ReadingListIngestor.ingestAllPending` already re-runs ordinary ingestion
    /// for every `.failed` item on launch, the item gets both paths without any
    /// extra scheduling.
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

    // MARK: - Inline trigger (from ReadingListIngestor)

    /// Called when a first-pass ingest ended `.failed`. Re-reads the item and, if
    /// still `.failed` and eligible, runs an INLINE rescue (interactive) or leaves
    /// it for the background sweep. Never blocks the caller.
    public func itemJustFailed(_ itemID: UUID, source: CaptureSource, interactive: Bool) {
        guard let engine = Self.engine, engine.isAvailable() else { return }
        guard interactive, ledger.shouldAutoRescue(itemID) else {
            // Non-interactive failures (background sweeps, extension saves) are
            // picked up by the debounced sweep, not rescued inline.
            return
        }
        Task { [weak self] in await self?.runRescue(itemID: itemID, hint: nil, interactive: true, countsAgainstBudget: true) }
    }

    /// A user-consented one-shot rescue (the failed card's button, a failed-row
    /// tap, the extension hand-off). Bypasses the auto-attempt budget — the tap
    /// IS consent — and spends the item's one Apple Intelligence attempt for this
    /// app version, so a card that comes back still failed goes terminal.
    public func requestManualRescue(itemID: UUID, hint: RescueHint?) {
        guard let engine = Self.engine, engine.isAvailable() else { return }
        Task { [weak self] in
            await self?.runRescue(
                itemID: itemID, hint: hint, interactive: true,
                countsAgainstBudget: false, spendsVersionAttempt: true)
        }
    }

    /// The same consented one-shot rescue as `requestManualRescue`, AWAITED, and
    /// reporting whether the item recovered.
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
        guard let engine = Self.engine, engine.isAvailable() else { return false }
        return await runRescue(
            itemID: itemID, hint: hint, interactive: true,
            countsAgainstBudget: false, spendsVersionAttempt: true)
    }

    /// Whether `itemID` is being rescued right now (for the "trying harder…" row).
    public func isRescuing(_ itemID: UUID) -> Bool {
        inFlightLock.lock(); defer { inFlightLock.unlock() }
        return inFlightItemIDs.contains(itemID)
    }

    // MARK: - Progress

    /// Called by the app shell's engine bridge as the rescue crosses each stage.
    /// Cheap and lock-scoped: it stores the stage and posts
    /// `.rescueProgressChanged` for the one card that cares, NOT
    /// `.readingListChanged` (which would reload every deck several times per
    /// rescue).
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

    private func scheduleSweep(debounced: Bool) {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runSweep() }
        debounceWorkItem = work
        workQueue.asyncAfter(deadline: .now() + (debounced ? debounceInterval : 0), execute: work)
    }

    private func runSweep() {
        guard let engine = Self.engine, engine.isAvailable() else { return }
        guard isForeground, !isSweeping else { return }
        isSweeping = true
        defer { isSweeping = false }

        let ingestor = ReadingListIngestor.shared
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
    }

    // MARK: - Run

    /// Returns whether the item advanced. Every early return is a false: the
    /// awaited caller (`rescueAndWait`) must not read "nothing to do" as success.
    @discardableResult
    private func runRescue(
        itemID: UUID, hint: RescueHint?, interactive: Bool,
        countsAgainstBudget: Bool, spendsVersionAttempt: Bool = false
    ) async -> Bool {
        guard let engine = Self.engine else { return false }
        // Re-read: the item may have advanced or been deleted since we scheduled.
        // Rescue anything not-yet-ready — the "only .failed" gating for AUTOMATIC
        // rescue is enforced at the call sites (itemJustFailed / the sweep); a
        // manual or drained request may target a still-.pending item.
        guard let item = store.item(withID: itemID), item.state != .ready else { return false }
        guard beginInFlight(itemID) else { return false }
        defer {
            endInFlight(itemID)
            postReadingListChanged()
        }

        if countsAgainstBudget { ledger.recordAttempt(itemID, hint: hint) }
        postReadingListChanged() // flip row to "trying harder…"

        let succeeded = await engine.perform(item, hint, interactive)
        if succeeded {
            ledger.recordSuccess(itemID, hint: hint)
        } else if spendsVersionAttempt {
            // The user asked for AI and AI didn't recover it. Record WHICH version
            // spent the attempt, so the card can say so plainly now and offer
            // itself again after the next update.
            failures.recordAIAttempt(itemID)
        }
        return succeeded
    }

    /// `.readingListChanged` is a UI-refresh notification, and its list/deck
    /// observers are selector-based — so they run on whatever thread posted, and
    /// then touch UIKit. `runRescue` runs on a task executor, not the main actor,
    /// so hop first (the same thing `ReadingListStore.postChanged` does for every
    /// store mutation; these two posts were the only ones that didn't).
    private func postReadingListChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .readingListChanged, object: nil)
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

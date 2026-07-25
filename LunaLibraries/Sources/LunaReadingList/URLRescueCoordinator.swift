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
    private let debounceInterval: TimeInterval
    private let workQueue = DispatchQueue(label: "com.hsanabria.luna.urlRescueCoordinator", qos: .utility)

    private var installed = false
    private var debounceWorkItem: DispatchWorkItem?
    private var isSweeping = false
    private var isForeground = true
    private let inFlightLock = NSLock()
    private var inFlightItemIDs: Set<UUID> = []

    private var notificationObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?

    /// Max items rescued per sweep pass (serialized, so this bounds concurrent LLM use).
    public static let sweepBatchLimit = 3

    public init(
        store: ReadingListStore = .shared,
        ledger: RescueLedgerStore = .shared,
        pending: PendingRescueRequestStore = .shared,
        debounceInterval: TimeInterval = 1.5
    ) {
        self.store = store
        self.ledger = ledger
        self.pending = pending
        self.debounceInterval = debounceInterval
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
        drainPendingRequests()
        scheduleSweep(debounced: false)
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

    /// A user-consented one-shot rescue (failed-row tap, extension hand-off).
    /// Bypasses the auto-attempt budget — the tap IS consent.
    public func requestManualRescue(itemID: UUID, hint: RescueHint?) {
        guard let engine = Self.engine, engine.isAvailable() else { return }
        Task { [weak self] in await self?.runRescue(itemID: itemID, hint: hint, interactive: true, countsAgainstBudget: false) }
    }

    /// Whether `itemID` is being rescued right now (for the "trying harder…" row).
    public func isRescuing(_ itemID: UUID) -> Bool {
        inFlightLock.lock(); defer { inFlightLock.unlock() }
        return inFlightItemIDs.contains(itemID)
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

    private func runRescue(itemID: UUID, hint: RescueHint?, interactive: Bool, countsAgainstBudget: Bool) async {
        guard let engine = Self.engine else { return }
        // Re-read: the item may have advanced or been deleted since we scheduled.
        // Rescue anything not-yet-ready — the "only .failed" gating for AUTOMATIC
        // rescue is enforced at the call sites (itemJustFailed / the sweep); a
        // manual or drained request may target a still-.pending item.
        guard let item = store.item(withID: itemID), item.state != .ready else { return }
        guard beginInFlight(itemID) else { return }
        defer {
            endInFlight(itemID)
            postReadingListChanged()
        }

        if countsAgainstBudget { ledger.recordAttempt(itemID, hint: hint) }
        postReadingListChanged() // flip row to "trying harder…"

        let succeeded = await engine.perform(item, hint, interactive)
        if succeeded { ledger.recordSuccess(itemID, hint: hint) }
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
    }
}

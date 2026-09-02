//
//  SellerComparison.swift
//  LunaPriceUI
//

import Foundation
import LunaModels
import LunaPriceCompare
import LunaStorage

/// The save-time comparison, as the surfaces use it: build the request from a
/// tracker, run the installed fan-out, attach what it found, and re-base the
/// alert baseline.
///
/// **Nobody waits for it.** A fan-out is up to 35 s of other people's web
/// servers. The save lands immediately with the one seller the user was
/// actually looking at, the run is marked PENDING on the tracker, and the
/// sellers arrive in the list as they are found. The one caller that still
/// waits is the Action Button intent, because its whole answer is a document
/// comparing them.
///
/// **The ORDER within a run is the other half of the design**, and it is not the
/// obvious one. A tracker is created from the SOURCE page alone and only then
/// grown, because `PriceTracker`'s multi-store initializer takes the CHEAPEST
/// store's currency as `initialCurrency` — build every seller up front and a
/// single foreign-currency listing that happens to be numerically lowest
/// silently redenominates the tracker, and the median computed against it is
/// meaningless. So: save from the source, `upsertStore` each verified seller as
/// it lands, and settle the baseline last, once every price is in.
public enum SellerComparison {

    /// The fan-out request for a tracker that has just been created from
    /// `sourceURL`. Every store already on the tracker is excluded, so a
    /// re-comparison never re-finds what it found last time — and a RESUMED run
    /// excludes whatever the dead process had already attached.
    public static func request(
        for tracker: PriceTracker, sourceURL: URL, categoryHints: [String] = []
    ) -> SellerFanOutRequest {
        var identifiers = tracker.identifiers
        if identifiers.brand == nil { identifiers.brand = tracker.brand }
        return SellerFanOutRequest(
            sourceURL: sourceURL,
            productName: tracker.productName,
            identifiers: identifiers,
            categoryHints: categoryHints,
            excludedURLStrings: tracker.stores.map(\.urlString),
            // The market is the SOURCE store's, never the device's:
            // `initialCurrency` is the currency of the page the tracker was
            // created from, and the engine refuses any result priced in
            // anything else.
            sourceCurrency: tracker.initialCurrency)
    }

    // MARK: - Starting

    /// Marks a just-saved tracker as awaiting a fan-out and returns whether it
    /// did. Persisted, because the process that starts a run is routinely gone
    /// before it ends — see `PriceTracker.PendingSellerComparison`.
    ///
    /// False when no fan-out is installed (a process that did not compose the
    /// product kind), so a surface that cannot compare shows no "checking…" row
    /// for a run that will never happen.
    @discardableResult
    public static func begin(
        itemID: UUID, sourceURL: URL, store: SavesStore, now: Date = Date()
    ) -> Bool {
        guard SellerComparisonRunner.installed != nil else { return false }
        guard var tracker = store.item(withID: itemID)?.priceTracker else { return false }
        // A plugin that returned `sellers` owns comparison for this tracker: it
        // already produced more than one store, all stamped with its id, so the
        // Swift fan-out would only re-find what the plugin handed over
        // (`claudedocs/plans/plugin-platform.md` §5.3). A plugin product with a
        // single store is compared normally.
        guard !(tracker.stores.count > 1 && tracker.stores.contains { $0.pluginID != nil })
        else { return false }
        tracker.beginPendingComparison(sourceURLString: sourceURL.absoluteString, at: now)
        store.updatePriceTracker(tracker, for: itemID)
        return true
    }

    /// Starts the run in the background: the save is finished, the card is
    /// already on screen, and the sellers land in the list behind it.
    public static func beginAndRunInBackground(
        itemID: UUID, sourceURL: URL, store: SavesStore, now: Date = Date()
    ) {
        guard begin(itemID: itemID, sourceURL: sourceURL, store: store, now: now) else { return }
        Task.detached(priority: .utility) {
            _ = await complete(itemID: itemID, store: store)
        }
    }

    // MARK: - Finishing

    /// Runs (or joins) the pending fan-out for one tracker and returns how many
    /// sellers it attached.
    ///
    /// Joining matters: the share extension starts a run, the user taps through
    /// to the intent's summary a moment later, and the second caller must WAIT
    /// for the first rather than start a duplicate fan-out over the same dozen
    /// retailers. `SellerComparisonTasks` is that rendezvous.
    @discardableResult
    public static func complete(
        itemID: UUID, store: SavesStore, now: Date = Date()
    ) async -> Int {
        await SellerComparisonTasks.shared.run(itemID: itemID) {
            await runPending(itemID: itemID, store: store, now: now)
        }
    }

    /// Finishes every tracker left mid-run by a process that died — called at
    /// launch and at the head of each background refresh cycle. Returns how many
    /// runs it finished.
    @discardableResult
    public static func completePending(
        store: SavesStore, now: Date = Date()
    ) async -> Int {
        guard SellerComparisonRunner.installed != nil else { return 0 }
        let pending = store.items().compactMap { item -> UUID? in
            guard let tracker = item.priceTracker, tracker.pendingComparison != nil,
                  !tracker.isArchived
            else { return nil }
            return item.id
        }
        var finished = 0
        for itemID in pending {
            _ = await complete(itemID: itemID, store: store, now: now)
            finished += 1
        }
        return finished
    }

    /// The run itself. Re-reads the tracker between every step, because the
    /// editor is open in front of the user the whole time this is happening.
    private static func runPending(
        itemID: UUID, store: SavesStore, now: Date
    ) async -> Int {
        // No runner in this process means nothing RAN, so the marker stays: a
        // later launch of an app that does compose the product kind picks it up.
        // Every other outcome — found nothing, budget expired, every retailer
        // bot-walled — is a finished run, and a marker that outlives its run is
        // a "checking…" row that never goes away.
        guard SellerComparisonRunner.installed != nil else { return 0 }
        guard let tracker = store.item(withID: itemID)?.priceTracker,
              let pending = tracker.pendingComparison,
              let sourceURL = URL(string: pending.sourceURLString)
        else { return 0 }

        let before = tracker.stores.count
        _ = await SellerComparisonRunner.run(
            request(for: tracker, sourceURL: sourceURL),
            onResult: { result in
                // Streamed: each verified seller is attached and persisted the
                // moment it lands, so the list fills in front of the user
                // rather than appearing all at once half a minute later.
                _ = attach(result, itemID: itemID, store: store, at: now)
            })

        guard var current = store.item(withID: itemID)?.priceTracker else { return 0 }
        current.completePendingComparison(at: now)
        store.updatePriceTracker(current, for: itemID)
        return max(0, current.stores.count - before)
    }

    // MARK: - Attaching

    /// Attaches ONE verified seller, if the tracker does not already hold that
    /// retailer. Returns whether it was added.
    ///
    /// The store gets BOTH a live price (`lastPrice`/`lastRefreshed`, so it
    /// reads as fetched-now rather than as passive history) and a recorded day
    /// sample, which is what makes today the first point of its graph.
    ///
    /// One store per retailer FAMILY: the engine already keys its own results by
    /// registrable domain, but the tracker may already hold a store on a host
    /// the engine had no reason to exclude (a redirect, a regional sibling), and
    /// two rows for the same shop is the one thing the store list must never
    /// show.
    @discardableResult
    public static func attach(
        _ result: ComparableSellerResult, itemID: UUID, store: SavesStore,
        at date: Date = Date()
    ) -> Bool {
        guard var tracker = store.item(withID: itemID)?.priceTracker else { return false }
        guard apply([result], to: &tracker, at: date) > 0 else { return false }
        store.updatePriceTracker(tracker, for: itemID)
        return true
    }

    /// Attaches every verified alternative seller to a tracker VALUE. Returns
    /// how many stores were added. Does not touch the baseline — that is
    /// `completePendingComparison`'s decision, once the whole run is in.
    @discardableResult
    public static func apply(
        _ results: [ComparableSellerResult], to tracker: inout PriceTracker,
        at date: Date = Date()
    ) -> Int {
        var claimedDomains = Set(
            tracker.stores.compactMap { store -> String? in
                guard let host = URL(string: store.urlString)?.host else { return nil }
                return ProductIdentityMatching.registrableDomain(host)
            })
        // The tracker-side half of the market rule: the engine already refuses
        // foreign-currency results, but a run resumed from an old pending
        // marker (or any other producer of results) must not attach one either
        // — a seller row in a currency the tracker cannot compare against is
        // exactly the "foreign store in the list" bug.
        let marketCurrency = tracker.initialCurrency.uppercased()
        var added = 0
        for result in results {
            let urlString = result.url.absoluteString
            guard result.currency.uppercased() == marketCurrency,
                  !tracker.hasStore(urlString: urlString),
                  // A fan-out is a passive writer: a seller the user removed
                  // from this tracker must not be re-attached by one, or the
                  // points they deleted come back at the next save.
                  !tracker.rejectsSeller(urlString: urlString),
                  claimedDomains.insert(result.domain).inserted
            else { continue }
            var store = PriceTrackerStore(
                urlString: urlString, lastPrice: result.price,
                currency: result.currency, lastRefreshed: date)
            store.recordSample(price: result.price, currency: result.currency, at: date)
            tracker.upsertStore(store)
            added += 1
        }
        return added
    }

}

/// The rendezvous for in-flight fan-outs, keyed by tracker.
///
/// Two things need it. A second caller for the same tracker must JOIN the run
/// rather than start a duplicate one — the intent's summary asking for a
/// comparison the share extension started a moment ago is the live case. And a
/// launch-time sweep must not race the run a still-alive extension is already
/// doing.
actor SellerComparisonTasks {
    static let shared = SellerComparisonTasks()

    private var inFlight: [UUID: Task<Int, Never>] = [:]

    func run(itemID: UUID, _ work: @escaping @Sendable () async -> Int) async -> Int {
        if let existing = inFlight[itemID] { return await existing.value }
        let task = Task<Int, Never> { await work() }
        inFlight[itemID] = task
        let result = await task.value
        inFlight[itemID] = nil
        return result
    }
}

//
//  BackgroundIngestCompletion.swift
//  LunaReadingList
//

import Foundation
import LunaModels
import LunaStorage

/// Finishes the saves a fast surface only had time to RESERVE, in the
/// background, without the user ever opening the app.
///
/// The one surface that needs this today is Safari's Download hand-off
/// (`claudedocs/safari-extension.md`): that launch persists the save, starts the
/// transfer, requests the Live Activity and bounces straight back to the page.
/// The row it leaves behind is `.pending` — no title, no kind — and the ordinary
/// launch/foreground `ingestAllPending` sweep would only finish it the next time
/// somebody happened to open the app. A deck full of blank rows waiting on a
/// launch defeats the point of the hand-off, so the app finishes the metadata
/// itself, after the bounce, under a background-execution lease.
///
/// This is the FALLBACK half of that story: normally the record itself carries
/// the metadata (the appex resolved the post to render its player) and
/// `PendingResolvedMediaDownloads.completeFromHandoff` finishes the row with no
/// network at all, settling the debt before this ever runs. What reaches here is
/// a record that could not answer for itself — an unfinished resolve, or a URL no
/// platform rule recognizes.
///
/// **What happens when the granted window expires mid-ingest.** The lease's
/// expiry cancels the ingest task at the ONE point that is safe to stop at:
/// `ReadingListIngestor.ingest` checks `Task.isCancelled` after the pipeline and
/// before it persists anything, so a cancelled pass writes nothing and the row
/// stays exactly `.pending` — never half-written. The debt stays in
/// `PendingIngestCompletions` with its attempt count bumped, and the next resume
/// point picks it up: the background `URLSession` running this very download
/// wakes the process when it finishes (`AppDelegate
/// .handleEventsForBackgroundURLSession`), and a launch runs the queue too. If
/// the process is killed outright, `ingestAllPending` is still the net — that
/// sweep is unchanged, it is simply no longer what the normal path depends on.
public enum BackgroundIngestCompletion {
    private static let lock = NSLock()
    private static var isRunning = false
    private static var observer: NSObjectProtocol?
    /// 100ms polls, so 60 seconds — longer than any ingest that is going to
    /// finish, short enough that a stuck one cannot hold the queue.
    private static let maximumWaitForARunningIngest = 600

    /// Whether this process may start an ingest NOBODY ASKED FOR — the observer
    /// and the app's own lifecycle triggers.
    ///
    /// False inside a test host, and that is not tidiness. The unit tests host
    /// on the central Luna app, so everything `AppDelegate` arms at launch is
    /// armed inside `LunaTests` too; a debt in the App-Group queue (a fixture's,
    /// or one a previous run left behind) would then make a REAL
    /// `ReadingListIngestor` pass run at an arbitrary moment mid-suite, fetching
    /// and driving WebKit capture against the same WebContent the archive tests
    /// are using. Suites that pass alone and fail together are exactly that.
    /// `LiveNetworkPolicy` closed the same class of problem for live traffic,
    /// and this is the same rule for background work.
    ///
    /// Tests still cover the feature — they call `run(store:completions:
    /// ingestor:)` EXPLICITLY, with their own stores, which is unaffected.
    private static var mayStartUnbiddenWork: Bool {
        !LiveNetworkPolicy.isRunningUnderXCTest
    }

    /// Starts listening for owed work. Called once at launch by the app shell —
    /// BEFORE the `resolvedmedia` drain can post its request, so a cold hand-off
    /// launch is not the one that misses it.
    public static func install() {
        guard mayStartUnbiddenWork else { return }
        lock.lock()
        guard observer == nil else { lock.unlock(); return }
        lock.unlock()
        let token = NotificationCenter.default.addObserver(
            forName: .pendingIngestCompletionsRequested, object: nil, queue: nil
        ) { _ in runFromLifecycle() }
        lock.lock()
        observer = token
        lock.unlock()
    }

    /// The app's own triggers — launch, and the background-`URLSession` wake
    /// that lands after a hand-off's download finishes. Same guard as
    /// `install()`: nothing the app starts BY ITSELF may run in a test host.
    public static func runFromLifecycle() {
        guard mayStartUnbiddenWork else { return }
        run()
    }

    /// Works the queue: one lease per owed row, ended the moment that row's
    /// ingest reaches a verdict. Re-entrant calls are dropped rather than
    /// queued — every trigger asks for the same thing, "finish what is owed",
    /// and the run already in flight is doing it.
    ///
    /// `completion` fires when the queue has been worked (a test seam, like
    /// `ingestAllPending`'s).
    public static func run(
        store: ReadingListStore = .shared,
        completions: PendingIngestCompletions = .shared,
        ingestor: ReadingListIngestor = .shared,
        completion: (() -> Void)? = nil
    ) {
        lock.lock()
        guard !isRunning else {
            lock.unlock()
            completion?()
            return
        }
        isRunning = true
        lock.unlock()
        Task {
            let queue = completions.owed()
            // Silent when there is nothing owed, which is the normal state; a
            // run that DOES find work says so, because the alternative is a
            // background ingest that starts, contends for something, and leaves
            // no trace of having run at all.
            if !queue.isEmpty {
                SharedDiagnosticLog.record(
                    "background ingest: finishing \(queue.count) owed row(s)",
                    category: "ingest")
            }
            for owed in queue {
                await finish(owed, store: store, completions: completions, ingestor: ingestor)
            }
            lock.withLock { isRunning = false }
            completion?()
        }
    }

    /// One owed row. Settles the debt for anything that already has a verdict —
    /// a row that was dropped by the surface gate, merged into a tracker, or
    /// finished by the sweep racing us at launch — and otherwise runs the
    /// ordinary ingest with no interactive prompt, exactly as the sweep would.
    private static func finish(
        _ owed: PendingIngestCompletion, store: ReadingListStore,
        completions: PendingIngestCompletions, ingestor: ReadingListIngestor
    ) async {
        // The launch sweep may already be ingesting this row. Two passes over
        // one item is a no-op inside the ingestor, but a no-op returns
        // immediately and would leave the debt looking unfinished; wait for the
        // pass that IS running instead — bounded, because a run that never ends
        // must not wedge the queue. Giving up here leaves the row owed, which is
        // the correct answer for "someone else is still working on it".
        var waited = 0
        while ingestor.isIngesting(owed.itemID) {
            guard waited < Self.maximumWaitForARunningIngest else { return }
            waited += 1
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let item = store.item(withID: owed.itemID), item.state == .pending else {
            completions.settle(owed.itemID)
            return
        }
        completions.recordAttempt(owed.itemID)
        let work = CancellableIngest()
        let lease = BackgroundExecutionLease(name: "FinishSaveIngest") {
            SharedDiagnosticLog.record(
                "background ingest window expired for \(owed.urlString) — "
                    + "row stays pending, resuming at the next wake",
                category: "ingest")
            work.cancel()
        }
        work.begin { _ = await ingestor.ingest(item, allowsInteractivePrompt: false) }
        await work.value()
        lease.end()
        // A row that reached ANY verdict — ready, failed, or gone (dropped by
        // the surface gate / merged into a tracker) — is settled. One left
        // `.pending` was cancelled by the expiry above and stays owed.
        if let current = store.item(withID: owed.itemID), current.state == .pending {
            SharedDiagnosticLog.record(
                "background ingest left \(owed.urlString) pending — still owed",
                category: "ingest")
        } else {
            completions.settle(owed.itemID)
        }
    }
}

/// A handle on the in-flight ingest so the lease's expiration closure — which
/// runs on iOS's schedule, from outside the task — can cancel it.
private final class CancellableIngest: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func begin(_ operation: @escaping @Sendable () async -> Void) {
        let task = Task { await operation() }
        lock.lock()
        let alreadyCancelled = cancelled
        self.task = task
        lock.unlock()
        if alreadyCancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func value() async {
        let task = lock.withLock { self.task }
        await task?.value
    }
}

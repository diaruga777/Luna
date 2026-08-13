//
//  BackgroundIngestCompletion.swift
//  LunaSaves
//

import Foundation
import LunaModels
import LunaStorage

/// Finishes, in the background, saves that a fast surface only had time to
/// reserve. The user never has to open the app.
///
/// Safari's Download hand-off is the one surface that needs this
/// (`claudedocs/safari-extension.md`). That launch persists the save, starts
/// the transfer, requests the Live Activity, and returns to the page. It
/// leaves a `.pending` row with no title and no kind. The ordinary
/// launch/foreground `ingestAllPending` sweep would only finish that row the
/// next time someone opened the app — and a deck full of blank rows defeats
/// the point of the hand-off. So the app finishes the metadata itself, right
/// after the bounce, under a background-execution lease.
///
/// This is the fallback path. Normally the record already carries its
/// metadata — the appex resolved the post to render its player — and
/// `PendingResolvedMediaDownloads.completeFromHandoff` finishes the row with
/// no network call, settling the debt before this code ever runs. This code
/// runs only for a record that could not answer for itself: an unfinished
/// resolve, or a URL no platform rule recognizes.
///
/// **When the granted window expires mid-ingest:** the lease's expiry cancels
/// the ingest task at the one point that is safe to stop — `SavesIngestor
/// .ingest` checks `Task.isCancelled` after the pipeline runs and before it
/// persists anything, so a cancelled pass writes nothing and the row stays
/// exactly `.pending`, never half-written. The debt stays in
/// `PendingIngestCompletions` with its attempt count bumped. The next resume
/// point picks it up: the background `URLSession` running this download wakes
/// the process when it finishes (`AppDelegate
/// .handleEventsForBackgroundURLSession`), and a launch also runs the queue.
/// If the process is killed outright, `ingestAllPending` is still the net —
/// unchanged, just no longer what the normal path depends on.
public enum BackgroundIngestCompletion {
    private static let lock = NSLock()
    private static var isRunning = false
    private static var observer: NSObjectProtocol?
    /// 100ms polls, so 60 seconds total — longer than any ingest that will
    /// finish, short enough that a stuck one cannot hold the queue.
    private static let maximumWaitForARunningIngest = 600

    /// Whether this process may start an ingest that nobody asked for — the
    /// observer and the app's own lifecycle triggers.
    ///
    /// This is false inside a test host, and that guards real behavior, not
    /// tidiness. The unit tests host on the central Luna app, so everything
    /// `AppDelegate` arms at launch is armed inside `LunaTests` too. A debt
    /// left in the App-Group queue — by a fixture, or by a previous run —
    /// would otherwise start a real `SavesIngestor` pass at an arbitrary
    /// moment mid-suite, fetching and driving WebKit capture against the same
    /// WebContent the archive tests use. A suite that passes alone and fails
    /// alongside others has exactly this cause. `LiveNetworkPolicy` closes the
    /// same class of problem for live traffic; this closes it for background
    /// work.
    ///
    /// Tests still cover the feature: they call `run(store:completions:
    /// ingestor:)` explicitly, with their own stores, so this guard does not
    /// affect them.
    private static var mayStartUnbiddenWork: Bool {
        !LiveNetworkPolicy.isRunningUnderXCTest
    }

    /// Starts listening for owed work. The app shell calls this once at
    /// launch, before the `resolvedmedia` drain can post its request, so a
    /// cold hand-off launch does not miss it.
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
    /// after a hand-off's download finishes. Same guard as `install()`:
    /// nothing the app starts by itself may run in a test host.
    public static func runFromLifecycle() {
        guard mayStartUnbiddenWork else { return }
        run()
    }

    /// Works the queue: one lease per owed row, ended the moment that row's
    /// ingest reaches a verdict. A re-entrant call is dropped, not queued —
    /// every trigger asks for the same thing, "finish what is owed", and the
    /// run already in flight is doing it.
    ///
    /// `completion` fires once the queue has been worked. It is a test seam,
    /// like `ingestAllPending`'s.
    public static func run(
        store: SavesStore = .shared,
        completions: PendingIngestCompletions = .shared,
        ingestor: SavesIngestor = .shared,
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
            // Silent when nothing is owed — the normal state. A run that does
            // find work logs it, because the alternative is a background
            // ingest that starts, contends for something, and leaves no trace
            // of having run.
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

    /// Settles one owed row. If the row already has a verdict — dropped by
    /// the surface gate, merged into a tracker, or finished by the launch
    /// sweep racing this call — this settles the debt directly. Otherwise it
    /// runs the ordinary ingest with no interactive prompt, exactly as the
    /// sweep would.
    private static func finish(
        _ owed: PendingIngestCompletion, store: SavesStore,
        completions: PendingIngestCompletions, ingestor: SavesIngestor
    ) async {
        // The launch sweep may already be ingesting this row. Two passes over
        // one item are a no-op inside the ingestor, but a no-op returns
        // immediately, which would make the debt look unfinished — so this
        // waits for the running pass instead, bounded so a pass that never
        // ends cannot wedge the queue. Giving up here leaves the row owed,
        // which is correct: someone else is still working on it.
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
        // A row that reached any verdict — ready, failed, or gone (dropped by
        // the surface gate, or merged into a tracker) — is settled. A row
        // still `.pending` was cancelled by the expiry above and stays owed.
        if let current = store.item(withID: owed.itemID), current.state == .pending {
            SharedDiagnosticLog.record(
                "background ingest left \(owed.urlString) pending — still owed",
                category: "ingest")
        } else {
            completions.settle(owed.itemID)
        }
    }
}

/// A handle on the in-flight ingest. The lease's expiration closure runs on
/// iOS's schedule, from outside the task, and uses this handle to cancel it.
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

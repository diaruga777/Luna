//
//  BackgroundExecutionLease.swift
//  LunaStorage
//

import Foundation
import UIKit

/// Keeps a short APP-OWNED leg of work alive when the user leaves the app.
///
/// Two features hold one, for the same reason: the leg has no system-owned task
/// backing it, so without a lease iOS may freeze the process mid-way.
///
///  - a background `URLSession` transfer's gaps — preflight before a task is
///    registered, local mux/trim work between tasks, final persistence after the
///    system delivered the file (`LiveMediaDownloadManager`);
///  - the metadata half of a save whose row a fast surface only had time to
///    RESERVE — Safari's Download hand-off bounces back to the page before the
///    ingest could run (`BackgroundIngestCompletion` in LunaSaves).
///
/// Two things it must never do, both learned the hard way:
///
///  - **Touch `UIApplication` in an `.appex`.** The share/action extensions reach
///    the very same media start path (`ShareViewController.autoDownloadThenComplete` →
///    `MediaAutoDownloader.startLiveActivityIfEnabled` → `start` →
///    `startReportingResult`), and `UIApplication.shared` returns nil in an app
///    extension — through Swift's non-optional bridge that is a trap, i.e. a
///    crash on every share-sheet media save. An extension has no app lifetime to
///    extend anyway (the host decides when it dies), so the lease is simply inert
///    there. Same `Bundle.main.bundleURL.pathExtension` test `NotificationManager`
///    and `GazeTracker` use.
///  - **Block a cooperative-pool thread on the main queue.** Leases are
///    constructed from `async` contexts, and a `DispatchQueue.main.sync` from one
///    of those is a priority inversion at exactly the busiest moment (launch,
///    where `resumeLiveActivities` now takes one). Acquisition hops
///    asynchronously instead; `end()` arriving first is handled rather than
///    raced — the begin block sees `hasEnded` and immediately returns the task it
///    was just given.
///
/// `onExpiration` runs when iOS is about to reclaim the granted window, BEFORE
/// the lease ends itself. A holder whose work must not be left half-done uses it
/// to cancel that work at a point it can be resumed from — the expiry is the one
/// moment the process still gets to choose what it leaves behind.
public final class BackgroundExecutionLease: @unchecked Sendable {
    private let lock = NSLock()
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var hasEnded = false

    /// No `UIApplication` here — see the type's note.
    private static var isAppExtension: Bool {
        Bundle.main.bundleURL.pathExtension == "appex"
    }

    public init(name: String, onExpiration: (@Sendable () -> Void)? = nil) {
        guard !Self.isAppExtension else {
            hasEnded = true
            return
        }
        let begin = { [weak self] in
            guard let self else { return }
            let taskIdentifier = UIApplication.shared.beginBackgroundTask(
                withName: name
            ) { [weak self] in
                onExpiration?()
                self?.end()
            }
            self.lock.lock()
            guard !self.hasEnded else {
                self.lock.unlock()
                if taskIdentifier != .invalid {
                    UIApplication.shared.endBackgroundTask(taskIdentifier)
                }
                return
            }
            self.identifier = taskIdentifier
            self.lock.unlock()
        }
        if Thread.isMainThread {
            begin()
        } else {
            DispatchQueue.main.async(execute: begin)
        }
    }

    public func end() {
        let taskIdentifier: UIBackgroundTaskIdentifier
        lock.lock()
        guard !hasEnded else {
            lock.unlock()
            return
        }
        hasEnded = true
        taskIdentifier = identifier
        identifier = .invalid
        lock.unlock()

        guard taskIdentifier != .invalid else { return }
        let finish = {
            UIApplication.shared.endBackgroundTask(taskIdentifier)
        }
        if Thread.isMainThread {
            finish()
        } else {
            DispatchQueue.main.async(execute: finish)
        }
    }

    deinit { end() }
}

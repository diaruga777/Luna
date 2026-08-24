//
//  XteinkRendezvousSweepPolicy.swift
//  Luna
//

import Foundation
import LunaStorage

/// The one decision every `.xteinkRendezvousReady` observer makes, shared so
/// the central Luna app and Reader don't carry two copies of it.
///
/// The sweep is a single sequential task: reconcile read-driven dequeues,
/// drain pending remote deletes, deliver every queued send one at a time,
/// then ALWAYS report `no_work` so the reader can close its window instead of
/// waiting out its idle cap. A read-report-only window exists purely to hand
/// back finished-reading ids (already drained by the status handler) and just
/// answers `no_work`. The whole sweep runs under `acquireSweepLock` so only
/// one Luna process talks to a given window (see `XteinkRendezvousSweepLock`);
/// a process that loses the lock stays completely silent.
public enum XteinkRendezvousSweepPolicy {
    public static func rendezvousBecameReady(
        isReadReportOnlyWindow: Bool,
        acquireSweepLock: () -> Bool,
        releaseSweepLock: @escaping @Sendable () -> Void,
        reconcileReadState: @escaping @Sendable () -> Void,
        drainPendingDeletes: @escaping @Sendable () async -> Void,
        deliverQueuedSends: @escaping @Sendable () async -> Void,
        reportNoWork: @escaping @Sendable () async throws -> Void
    ) {
        guard acquireSweepLock() else {
            SharedDiagnosticLog.record(
                "Sweep skipped: another Luna app owns this rendezvous", category: "xteink")
            return
        }
        Task {
            defer { releaseSweepLock() }
            if isReadReportOnlyWindow {
                try? await reportNoWork()
                return
            }
            reconcileReadState()
            await drainPendingDeletes()
            await deliverQueuedSends()
            // Concluding the window is unconditional: after everything this
            // sweep could do (even if some of it failed), the reader must be
            // released rather than left hanging until its idle timeout.
            do {
                try await reportNoWork()
            } catch {
                SharedDiagnosticLog.record("no_work not delivered: \(error)", category: "xteink")
            }
        }
    }
}

//
//  XteinkRendezvousSweepPolicy.swift
//  Luna
//

import Foundation

/// The one decision every `.xteinkRendezvousReady` observer makes, shared so
/// the central Luna app and Reader don't carry two copies of it. A
/// read-report-only window exists purely to hand back finished-reading ids
/// (already drained by the status handler) and never sweeps sends or deletes.
/// A normal window reconciles read-driven dequeues, drains any pending
/// remote deletes, then sweeps queued sends if any remain — or answers
/// `reportNoWork()` if not.
public enum XteinkRendezvousSweepPolicy {
    public static func rendezvousBecameReady(
        isReadReportOnlyWindow: Bool,
        reconcileReadState: () -> Void,
        drainPendingDeletes: @escaping () async -> Void,
        hasQueuedSend: @escaping () -> Bool,
        retryPendingSends: @escaping () -> Void,
        reportNoWork: @escaping @Sendable () async throws -> Void
    ) {
        guard !isReadReportOnlyWindow else {
            Task { try? await reportNoWork() }
            return
        }
        reconcileReadState()
        Task {
            await drainPendingDeletes()
            if hasQueuedSend() {
                retryPendingSends()
            } else {
                try? await reportNoWork()
            }
        }
    }
}

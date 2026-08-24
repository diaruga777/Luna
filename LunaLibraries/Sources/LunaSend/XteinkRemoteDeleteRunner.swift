//
//  XteinkRemoteDeleteRunner.swift
//  Luna
//

import Foundation
import LunaModels
import LunaStorage

/// Drains delivered Xteink books whose article was finished reading in Luna
/// (not on the device — that path never reaches `.deletePending`, see
/// `SavesStore.markRemoteDeliveryReadOnDevice`). Runs in a normal (non
/// read-report) rendezvous window, before the queued-send sweep: the delete
/// control op is cheap and the device is already awake for it.
public enum XteinkRemoteDeleteRunner {

    /// One at a time through the existing `delete` control op / op-ack
    /// machinery. A delete left pending after a protocol error just waits for
    /// the next window — the caller does not need to know which ones stuck.
    public static func drainPendingDeletes(
        ble: any XteinkBLETransporting = XteinkBLECentral.shared,
        store: SavesStore = .shared
    ) async {
        let destination = ArticleDestinationID.xteink
        for item in store.items() {
            guard item.remoteDeleteStatus(for: destination) == .deletePending,
                  let remoteName = item.remoteName(for: destination)
            else { continue }
            do {
                try await ble.delete(remotePath: remoteName)
                store.markRemoteDeliveryDeleted(for: item.id, destination: destination)
            } catch {
                guard isMissingFileError(error) else { continue }
                // The device treats a missing file as its own success ack, so
                // this only fires against an older reader build or a
                // still-different error string — either way the remote copy
                // is already gone.
                store.markRemoteDeliveryDeleted(for: item.id, destination: destination)
            }
        }
    }

    private static func isMissingFileError(_ error: Error) -> Bool {
        guard case XteinkSyncError.protocolError(let message) = error else { return false }
        let normalized = message.lowercased()
        return normalized.contains("no such file")
            || normalized.contains("not found")
            || normalized.contains("enoent")
    }
}

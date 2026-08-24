//
//  XteinkReadStateReconciler.swift
//  Luna
//

import Foundation
import LunaModels
import LunaStorage

/// Keeps a still-queued Xteink send in step with whether its article has
/// already been finished. A save read to the end before its send went out is
/// not worth spending a BLE window on — the reader would receive a book its
/// owner already considers done. A send whose immunity flag was recorded at
/// enqueue time (the user deliberately (re-)sent an already-read article) is
/// exempt and stays queued regardless of read state.
public enum XteinkReadStateReconciler {
    private static var observer: NSObjectProtocol?

    /// Starts watching `.savesChanged` for read-driven dequeues. Idempotent —
    /// call once per process at launch.
    public static func startObservingSaveChanges(store: SavesStore = .shared) {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .savesChanged, object: nil, queue: .main
        ) { _ in dequeueSendsFinishedBeforeDelivery(store: store) }
    }

    /// Unqueues every Xteink send whose article reached `.read` before
    /// delivery. Called on every saves change and again immediately before a
    /// rendezvous sweep decides whether it has work.
    public static func dequeueSendsFinishedBeforeDelivery(store: SavesStore = .shared) {
        let destination = ArticleDestinationID.xteink
        for item in store.items() {
            guard item.sendState(for: destination) == .queued,
                  item.readState == .read,
                  !item.queuedWhileRead(for: destination)
            else { continue }
            store.clearSendState(for: item.id, destination: destination)
        }
    }
}

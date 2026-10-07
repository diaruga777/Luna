//
//  ReadStateSendReconciler.swift
//  Luna
//

import Foundation
import LunaModels
import LunaStorage

/// Keeps a still-queued send in step with whether its save has already been
/// finished. It serves every destination whose `dequeuesOnRead` is true: such
/// a receiver files a delivered book away on its own, so a save read to the
/// end before its send went out is not worth spending a delivery window on.
public enum ReadStateSendReconciler {
    private static var observer: NSObjectProtocol?

    /// Starts watching `.savesChanged` for read-driven dequeues. Idempotent —
    /// call once per process at launch.
    public static func startObservingSaveChanges(store: SavesStore = .shared) {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .savesChanged, object: nil, queue: .main
        ) { _ in dequeueSendsFinishedBeforeDelivery(store: store) }
    }

    /// Reconciles every dequeue-on-read destination the shared coordinator
    /// serves right now. A destination plugin joins that set the moment the
    /// plugin platform installs it, so the list is read per call.
    public static func dequeueSendsFinishedBeforeDelivery(store: SavesStore = .shared) {
        dequeueSendsFinishedBeforeDelivery(
            destinationIDs: ArticleSendCoordinator.shared.dequeueOnReadDestinationIDs(),
            store: store)
    }

    /// Unqueues every send to `destinationIDs` whose save reached `.read`
    /// before delivery. The coordinator calls this for one destination
    /// immediately before that destination's queue is swept.
    public static func dequeueSendsFinishedBeforeDelivery(
        destinationIDs: [String], store: SavesStore = .shared
    ) {
        guard !destinationIDs.isEmpty else { return }
        for item in store.items() where item.readState == .read {
            for destination in destinationIDs {
                guard item.sendState(for: destination) == .queued else { continue }
                store.clearSendState(for: item.id, destination: destination)
            }
        }
    }
}

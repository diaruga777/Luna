//
//  PluginExportsBridge.swift
//  LunaPluginExport
//

import Foundation
import JavaScriptCore
import LunaModels
import LunaPluginKit
import LunaPluginRuntime
import LunaSend
import LunaStorage

/// One save queued for a destination, as `luna.exports.queued()` answers it.
public struct PluginQueuedSend: Equatable {
    public let saveID: UUID
    public let title: String
    public let queuedAt: Date?

    public init(saveID: UUID, title: String, queuedAt: Date?) {
        self.saveID = saveID
        self.title = title
        self.queuedAt = queuedAt
    }
}

/// One delivered save whose remote copy is now stale, as
/// `luna.exports.pendingDeletes()` answers it. A row exists only once Luna
/// knows the name the receiver filed the save under, which is the only thing
/// a delete op can name.
public struct PluginPendingRemoteDelete: Equatable {
    public let saveID: UUID
    public let title: String
    public let remoteName: String

    public init(saveID: UUID, title: String, remoteName: String) {
        self.saveID = saveID
        self.title = title
        self.remoteName = remoteName
    }
}

/// The send queue of one destination, as the bridge reads and drives it. The
/// shipped conformer is the send coordinator plus the saves store; a test
/// drives an in-memory queue.
public protocol PluginExportQueueDriving: AnyObject {
    func queuedSends(forDestinationID id: String) -> [PluginQueuedSend]
    /// Delivers everything queued, ignoring backoff. Returns what it delivered
    /// and what it left.
    func deliverQueuedSends(forDestinationID id: String) async -> (delivered: Int, remaining: Int)
    /// Marks one save sent without delivering it — the reconciliation a
    /// receiving device's own report needs.
    func markSent(saveID: UUID, destinationID: String)
    /// Delivered saves whose reading finished in Luna, so their remote copy
    /// is stale and the receiver should drop it.
    func pendingRemoteDeletes(forDestinationID id: String) -> [PluginPendingRemoteDelete]
    /// The receiver confirmed the remote copy is gone.
    func markRemoteDeleted(saveID: UUID, destinationID: String)
    /// The receiver reported the save finished ON the device.
    func markReadOnDevice(saveID: UUID, destinationID: String)
}

/// `luna.exports` (`claudedocs/plans/plugin-platform.md` §6.16): a destination
/// plugin driving its own queue.
///
/// A plugin sees only ITS destination's queue. The id is the destination's, so
/// a plugin that replaced a Swift destination reads the queue that destination
/// already had.
public final class PluginExportsBridge: PluginCapabilityInstalling {

    public let capabilityName = PluginCapabilityName.exports

    private let processKind: PluginProcessKind
    private let scheduler: PluginCallbackScheduling
    private let queue: any PluginExportQueueDriving

    public init(
        processKind: PluginProcessKind,
        scheduler: PluginCallbackScheduling,
        queue: (any PluginExportQueueDriving)? = nil
    ) {
        self.processKind = processKind
        self.scheduler = scheduler
        self.queue = queue ?? CoordinatorPluginExportQueue()
    }

    public func install(into namespace: PluginCapabilityNamespace) {
        let outerContext = namespace.context
        let bridge = self
        let destinationID = PluginDestinationLegacyIDs.destinationID(forPluginID: namespace.pluginID)
        let exports = namespace.makeNamespaceObject()

        let deliverQueued: @convention(block) () -> JSValue? = {
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: bridge.scheduler)
            guard bridge.processKind == .app else {
                box.fail("luna.exports.deliverQueued needs the app", code: "unavailable-here")
                return promise
            }
            Task {
                let counts = await bridge.queue.deliverQueuedSends(
                    forDestinationID: destinationID)
                box.fulfill(["delivered": counts.delivered, "remaining": counts.remaining])
            }
            return promise
        }

        let queued: @convention(block) () -> JSValue? = {
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: bridge.scheduler)
            let formatter = ISO8601DateFormatter()
            box.fulfill(bridge.queue.queuedSends(forDestinationID: destinationID).map { send in
                var row: [String: Any] = [
                    "saveId": send.saveID.uuidString,
                    "title": send.title,
                ]
                if let queuedAt = send.queuedAt {
                    row["queuedAt"] = formatter.string(from: queuedAt)
                }
                return row
            })
            return promise
        }

        let markSent: @convention(block) (String?) -> JSValue? = { saveID in
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: bridge.scheduler)
            guard bridge.processKind == .app else {
                box.fail("luna.exports.markSent needs the app", code: "unavailable-here")
                return promise
            }
            guard let saveID, let id = UUID(uuidString: saveID) else {
                box.fail("luna.exports.markSent needs a save id", code: "bad-argument")
                return promise
            }
            bridge.queue.markSent(saveID: id, destinationID: destinationID)
            box.fulfill(NSNull())
            return promise
        }

        let pendingDeletes: @convention(block) () -> JSValue? = {
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: bridge.scheduler)
            guard bridge.processKind == .app else {
                box.fail("luna.exports.pendingDeletes needs the app", code: "unavailable-here")
                return promise
            }
            box.fulfill(
                bridge.queue.pendingRemoteDeletes(forDestinationID: destinationID).map {
                    [
                        "saveId": $0.saveID.uuidString,
                        "title": $0.title,
                        "remoteName": $0.remoteName,
                    ]
                })
            return promise
        }

        let markRemoteDeleted = bridge.saveIDBlock(
            named: "markRemoteDeleted", outerContext: outerContext
        ) { saveID in
            bridge.queue.markRemoteDeleted(saveID: saveID, destinationID: destinationID)
        }

        let markReadOnDevice = bridge.saveIDBlock(
            named: "markReadOnDevice", outerContext: outerContext
        ) { saveID in
            bridge.queue.markReadOnDevice(saveID: saveID, destinationID: destinationID)
        }

        exports.setObject(deliverQueued, forKeyedSubscript: "deliverQueued" as NSString)
        exports.setObject(queued, forKeyedSubscript: "queued" as NSString)
        exports.setObject(markSent, forKeyedSubscript: "markSent" as NSString)
        exports.setObject(pendingDeletes, forKeyedSubscript: "pendingDeletes" as NSString)
        exports.setObject(markRemoteDeleted, forKeyedSubscript: "markRemoteDeleted" as NSString)
        exports.setObject(markReadOnDevice, forKeyedSubscript: "markReadOnDevice" as NSString)
        namespace.install(exports, as: capabilityName.rawValue)
    }

    /// The three bookkeeping calls differ only in what they do with the id, so
    /// the app gate, the id parse and the empty fulfilment are written once.
    private func saveIDBlock(
        named name: String, outerContext: JSContext,
        _ apply: @escaping (UUID) -> Void
    ) -> @convention(block) (String?) -> JSValue? {
        let scheduler = self.scheduler
        let processKind = self.processKind
        return { saveID in
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            guard processKind == .app else {
                box.fail("luna.exports.\(name) needs the app", code: "unavailable-here")
                return promise
            }
            guard let saveID, let id = UUID(uuidString: saveID) else {
                box.fail("luna.exports.\(name) needs a save id", code: "bad-argument")
                return promise
            }
            apply(id)
            box.fulfill(NSNull())
            return promise
        }
    }
}

/// The real queue: the saves store's send states, drained by
/// `ArticleSendCoordinator`.
public final class CoordinatorPluginExportQueue: PluginExportQueueDriving {

    private let store: SavesStore

    public init(store: SavesStore = .shared) {
        self.store = store
    }

    public func queuedSends(forDestinationID id: String) -> [PluginQueuedSend] {
        store.items()
            .filter { $0.sendState(for: id) == .queued }
            .map {
                PluginQueuedSend(
                    saveID: $0.id, title: $0.title ?? $0.urlString,
                    // A queued row records no queue time of its own; the
                    // save's own date is the honest answer.
                    queuedAt: $0.dateAdded)
            }
    }

    public func deliverQueuedSends(
        forDestinationID id: String
    ) async -> (delivered: Int, remaining: Int) {
        let before = queuedSends(forDestinationID: id).count
        await ArticleSendCoordinator.shared.deliverQueuedSends(toDestinationID: id)
        let remaining = queuedSends(forDestinationID: id).count
        return (delivered: max(0, before - remaining), remaining: remaining)
    }

    public func markSent(saveID: UUID, destinationID: String) {
        store.setSendState(.sent, for: saveID, destination: destinationID)
    }

    public func pendingRemoteDeletes(
        forDestinationID id: String
    ) -> [PluginPendingRemoteDelete] {
        store.items().compactMap { item in
            guard item.remoteDeleteStatus(for: id) == .deletePending,
                  let remoteName = item.remoteName(for: id)
            else { return nil }
            return PluginPendingRemoteDelete(
                saveID: item.id, title: item.title ?? item.urlString,
                remoteName: remoteName)
        }
    }

    public func markRemoteDeleted(saveID: UUID, destinationID: String) {
        store.markRemoteDeliveryDeleted(for: saveID, destination: destinationID)
    }

    /// The order is the whole point, and it mirrors `XteinkBLECentral
    /// .handleReadIDs`: moving the delivery to `.readOnDevice` FIRST is what
    /// stops `markFinishedReading` from also queueing a remote delete for a
    /// book the receiver already filed away itself.
    public func markReadOnDevice(saveID: UUID, destinationID: String) {
        store.markRemoteDeliveryReadOnDevice(for: saveID, destination: destinationID)
        store.markFinishedReading(saveID)
    }
}

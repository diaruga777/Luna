//
//  XteinkPluginFakes.swift
//  LunaTests
//

import Foundation
import JavaScriptCore
import LunaPluginExport
import LunaPluginKit
import LunaPluginRuntime
import LunaPluginTransport
import LunaStorage

/// An X3 reader on the other end of a GATT link.
///
/// It speaks the CrossPoint `luna_sync` protocol the way the firmware does:
/// it answers each control operation with a matching `op_ack`, confirms
/// durable receipt at every checkpoint boundary, and publishes its stride as
/// `ckpt`. A test therefore asserts on what the READER saw — the bytes it
/// assembled, the in-flight window it was held to — rather than on the
/// plugin's own bookkeeping.
final class FakeXteinkReaderTransport: PluginBluetoothTransporting, @unchecked Sendable {

    static let service = "6F9F0A00-9B1D-4D1F-9F53-5B6B8B3D0F10"
    static let control = "6F9F0A01-9B1D-4D1F-9F53-5B6B8B3D0F10"
    static let dataIn = "6F9F0A02-9B1D-4D1F-9F53-5B6B8B3D0F10"
    static let status = "6F9F0A03-9B1D-4D1F-9F53-5B6B8B3D0F10"
    static let dataOut = "6F9F0A04-9B1D-4D1F-9F53-5B6B8B3D0F10"

    weak var transportDelegate: PluginBluetoothTransportDelegate?

    var state: PluginBluetoothState = .poweredOn
    var nonce = "9f3c0b71"
    /// The reader's durable-receipt stride, as the current firmware declares it.
    var checkpointIntervalBytes = 2048
    var writeLength = 184
    var canWrite = true
    /// A read-report ping window: the reader opened it purely to hand ids back.
    var isReadReportWindow = false
    /// Finished-reading ids the reader hands back. It publishes at most
    /// `readIDBatch` per status and sends the next batch after each
    /// `read_ack`, which is what the firmware does.
    var readIDs: [String] = []
    let readIDBatch = 2
    /// A protocol error to answer `start_put` with, e.g. "exists".
    var startPutError: String?
    /// The network the reader offers for an oversized book.
    var wifiOffer: [String: Any]?

    private let lock = NSLock()
    private(set) var controlOperations: [[String: Any]] = []
    private(set) var assembled = Data()
    private(set) var maximumUnconfirmedBytes = 0
    private var lastConfirmed = 0
    private var remainingReadIDs: [String]?

    var operationNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return controlOperations.compactMap { $0["op"] as? String }
    }

    func operation(_ name: String) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return controlOperations.last { ($0["op"] as? String) == name }
    }

    // MARK: - PluginBluetoothTransporting

    func startScan(services: [String]) {}
    func stopScan() {}
    func connect(deviceID: String) {}
    func cancelConnection(deviceID: String) {}
    func knownDevices(ids: [String]) -> [PluginBluetoothDevice] { [] }
    func maximumWriteLength(deviceID: String) -> Int { writeLength }
    func canWriteWithoutResponse(deviceID: String) -> Bool { canWrite }
    func releaseForAccessoryPicker(completion: @escaping () -> Void) { completion() }
    func rebuildAfterAccessoryPicker() {}

    func discover(
        serviceUUID: String, deviceID: String,
        completion: @escaping (Result<[String], PluginTransportError>) -> Void
    ) {
        guard serviceUUID.uppercased() == Self.service else {
            return completion(.failure(PluginTransportError(
                code: "no-service", message: "the reader has no \(serviceUUID)")))
        }
        completion(.success([Self.control, Self.dataIn, Self.status, Self.dataOut]))
    }

    func subscribe(
        characteristicUUID: String, deviceID: String,
        completion: @escaping (Result<Void, PluginTransportError>) -> Void
    ) {
        completion(.success(()))
    }

    /// The reader publishes its nonce when the link opens. An explicit read is
    /// how the phone gets it even when the notification preceded the subscribe.
    func read(
        characteristicUUID: String, deviceID: String,
        completion: @escaping (Result<String, PluginTransportError>) -> Void
    ) {
        var status: [String: Any] = ["nonce": nonce, "ckpt": checkpointIntervalBytes]
        if isReadReportWindow { status["win"] = "rr" }
        completion(.success(Self.encode(status)))
    }

    func write(
        base64: String, characteristicUUID: String, deviceID: String, withResponse: Bool,
        completion: @escaping (Result<Void, PluginTransportError>) -> Void
    ) {
        let uuid = characteristicUUID.uppercased()
        guard let data = Data(base64Encoded: base64) else {
            return completion(.failure(PluginTransportError(
                code: "bad-frame", message: "not base64")))
        }
        completion(.success(()))
        if uuid == Self.control {
            handleControl(data)
        } else if uuid == Self.dataIn {
            handleFrame(data)
        }
    }

    // MARK: - The protocol

    private func handleControl(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = object["op"] as? String
        else { return }
        lock.lock()
        controlOperations.append(object)
        lock.unlock()

        switch op {
        case "hello":
            var status: [String: Any] = ["op_ack": "hello", "ok": true, "nonce": nonce]
            if isReadReportWindow { status["win"] = "rr" }
            lock.lock()
            let pending = remainingReadIDs ?? readIDs
            remainingReadIDs = pending
            lock.unlock()
            if !pending.isEmpty { status["read_ids"] = Array(pending.prefix(readIDBatch)) }
            publish(status)
        case "start_put":
            if let startPutError {
                publish(["ok": false, "error": startPutError])
                return
            }
            lock.lock()
            assembled = Data()
            lastConfirmed = 0
            maximumUnconfirmedBytes = 0
            lock.unlock()
            publish([
                "op_ack": "start_put", "ok": true, "resume_offset": 0,
                "next_sequence": 0, "ckpt": checkpointIntervalBytes,
            ])
        case "wifi_request":
            var status: [String: Any] = ["op_ack": "wifi_request", "ok": true]
            if let wifiOffer { status["wifi"] = wifiOffer }
            publish(status)
        case "read_ack":
            // A plain write, not a control operation: no op_ack. The reader
            // drops the acked ids and offers the next batch.
            let acked = Set((object["ids"] as? [String]) ?? [])
            lock.lock()
            remainingReadIDs = (remainingReadIDs ?? readIDs).filter { !acked.contains($0) }
            let next = Array((remainingReadIDs ?? []).prefix(readIDBatch))
            lock.unlock()
            if !next.isEmpty { publish(["read_ids": next]) }
        default:
            publish(["op_ack": op, "ok": true])
        }
    }

    /// A data frame is a 4-byte little-endian sequence header, then payload.
    /// The reader confirms durable receipt at each checkpoint boundary.
    private func handleFrame(_ data: Data) {
        guard data.count > 4 else { return }
        let payload = data.dropFirst(4)
        lock.lock()
        assembled.append(payload)
        let unconfirmed = assembled.count - lastConfirmed
        maximumUnconfirmedBytes = max(maximumUnconfirmedBytes, unconfirmed)
        let shouldConfirm = unconfirmed >= checkpointIntervalBytes
        if shouldConfirm { lastConfirmed = assembled.count }
        let received = assembled.count
        lock.unlock()
        guard shouldConfirm else { return }
        publish(["received": received, "ckpt": checkpointIntervalBytes])
    }

    private func publish(_ status: [String: Any]) {
        transportDelegate?.bluetoothTransport(
            didReceive: Self.encode(status), characteristicUUID: Self.status,
            deviceID: "reader")
    }

    static func encode(_ status: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: status)) ?? Data()
        return data.base64EncodedString()
    }

    func fireConnect(_ device: PluginBluetoothDevice) {
        transportDelegate?.bluetoothTransportDidConnect(device, restored: false)
    }
}

/// The system accessory picker, recording rather than presenting. Answering
/// nil is the "user dismissed it" path, which is enough to see whether the
/// plugin asked for the picker at all.
final class FakeXteinkAccessoryPairing: PluginAccessoryPairing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var pickerRequests = 0
    private(set) var removedAccessories: [String] = []

    func showPicker(
        serviceUUIDs: [String], displayName: String,
        completion: @escaping (Result<PluginBluetoothDevice?, PluginTransportError>) -> Void
    ) {
        lock.lock(); pickerRequests += 1; lock.unlock()
        completion(.success(nil))
    }

    func removeSetUpAccessories(completion: @escaping () -> Void) { completion() }

    func removeAccessory(deviceID: String, completion: @escaping () -> Void) {
        lock.lock(); removedAccessories.append(deviceID); lock.unlock()
        completion()
    }

    var pickerWasShown: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pickerRequests > 0
    }
}

/// The transport witnesses for a fake reader.
final class FakeXteinkTransportMaker: PluginTransportMaking, @unchecked Sendable {

    let transport = FakeXteinkReaderTransport()
    let lease = FakePluginBackgroundLease()
    let pairing = FakeXteinkAccessoryPairing()
    private let serviceLock: BluetoothServiceLock

    init(lockFileURL: URL) {
        serviceLock = BluetoothServiceLock(fileURL: lockFileURL)
    }

    func makeTransport(pluginID: String) -> any PluginBluetoothTransporting { transport }
    func makePairing(pluginID: String) -> (any PluginAccessoryPairing)? { pairing }
    func makeServiceLock(serviceUUID: String) -> BluetoothServiceLock { serviceLock }
    func makeLease() -> (any PluginBackgroundLeasing)? { lease }
}

/// `luna.exports` with a real send queue underneath its bookkeeping.
///
/// `deliverQueued`/`queued` are the fake half: they run the real nesting a
/// destination plugin produces, invoking the plugin's own `export` hook from
/// inside its `onBluetooth` call, over sends a test declares directly. The
/// three BOOKKEEPING calls — `markSent`, `pendingDeletes`, `markRemoteDeleted`
/// and `markReadOnDevice` — go through the shipped `CoordinatorPluginExportQueue`
/// onto a scratch `SavesStore`, so what the plugin does to a save is what
/// production would do to it.
final class FakePluginExportsBridge: PluginCapabilityInstalling, @unchecked Sendable {

    /// One queued send, as `ExportInput` (§9.2).
    struct QueuedSend: Encodable {
        let kind = "article"
        let saveId: String
        let url: String
        let title: String
        let format = "epub"
        let file: FileHandleJSON
        let auto = true
        let queuedRemaining: Int

        struct FileHandleJSON: Encodable {
            let id: String
            let name: String
            let size: Int
            let mime: String
        }
    }

    let capabilityName = PluginCapabilityName.exports

    var queued: [QueuedSend] = []

    private let scheduler: PluginCallbackScheduling
    private let invoker: any PluginHookInvoking
    private let pluginID: String
    private let destinationID: String
    private let queue: any PluginExportQueueDriving
    private let lock = NSLock()
    private(set) var markedSent: [String] = []
    private(set) var markedReadOnDevice: [String] = []
    private(set) var sentNames: [String] = []
    private(set) var exportResults: [String] = []

    init(
        scheduler: PluginCallbackScheduling, invoker: any PluginHookInvoking, pluginID: String,
        store: SavesStore
    ) {
        self.scheduler = scheduler
        self.invoker = invoker
        self.pluginID = pluginID
        destinationID = PluginDestinationLegacyIDs.destinationID(forPluginID: pluginID)
        queue = CoordinatorPluginExportQueue(store: store)
    }

    struct ExportAnswer: Decodable {
        let status: String?
        let message: String?
        let remoteName: String?
    }

    func install(into namespace: PluginCapabilityNamespace) {
        let outerContext = namespace.context
        let scheduler = self.scheduler
        let bridge = self
        let exports = namespace.makeNamespaceObject()

        let deliverQueued: @convention(block) () -> JSValue? = {
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            Task { [bridge] in
                var delivered = 0
                for send in bridge.queued {
                    let outcome = await bridge.invoker.invoke(
                        .export, pluginID: bridge.pluginID, argument: send,
                        timeout: 30, decode: ExportAnswer?.self)
                    bridge.lock.lock()
                    switch outcome {
                    case .success(let answer):
                        bridge.exportResults.append(answer?.status ?? "null")
                        if answer?.status == "sent" {
                            delivered += 1
                            if let name = answer?.remoteName {
                                bridge.sentNames.append(name)
                            }
                        }
                    case .failure(let failure):
                        bridge.exportResults.append("failure:\(failure)")
                    }
                    bridge.lock.unlock()
                }
                box.fulfill(["delivered": delivered, "remaining": 0])
            }
            return promise
        }

        let queuedList: @convention(block) () -> JSValue? = {
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            box.fulfill(bridge.queued.map { ["saveId": $0.saveId, "title": $0.title] })
            return promise
        }

        let markSent = bridge.saveIDBlock(outerContext) { id, text in
            bridge.lock.lock()
            bridge.markedSent.append(text)
            bridge.lock.unlock()
            bridge.queue.markSent(saveID: id, destinationID: bridge.destinationID)
        }

        let markReadOnDevice = bridge.saveIDBlock(outerContext) { id, text in
            bridge.lock.lock()
            bridge.markedReadOnDevice.append(text)
            bridge.lock.unlock()
            bridge.queue.markReadOnDevice(saveID: id, destinationID: bridge.destinationID)
        }

        let markRemoteDeleted = bridge.saveIDBlock(outerContext) { id, _ in
            bridge.queue.markRemoteDeleted(saveID: id, destinationID: bridge.destinationID)
        }

        let pendingDeletes: @convention(block) () -> JSValue? = {
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            box.fulfill(
                bridge.queue.pendingRemoteDeletes(forDestinationID: bridge.destinationID).map {
                    [
                        "saveId": $0.saveID.uuidString,
                        "title": $0.title,
                        "remoteName": $0.remoteName,
                    ]
                })
            return promise
        }

        exports.setObject(deliverQueued, forKeyedSubscript: "deliverQueued" as NSString)
        exports.setObject(queuedList, forKeyedSubscript: "queued" as NSString)
        exports.setObject(markSent, forKeyedSubscript: "markSent" as NSString)
        exports.setObject(markReadOnDevice, forKeyedSubscript: "markReadOnDevice" as NSString)
        exports.setObject(markRemoteDeleted, forKeyedSubscript: "markRemoteDeleted" as NSString)
        exports.setObject(pendingDeletes, forKeyedSubscript: "pendingDeletes" as NSString)
        namespace.install(exports, as: capabilityName.rawValue)
    }

    private func saveIDBlock(
        _ outerContext: JSContext, _ apply: @escaping (UUID, String) -> Void
    ) -> @convention(block) (String?) -> JSValue? {
        let scheduler = self.scheduler
        return { saveID in
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            guard let saveID, let id = UUID(uuidString: saveID) else {
                box.fail("this call needs a save id", code: "bad-argument")
                return promise
            }
            apply(id, saveID)
            box.fulfill(NSNull())
            return promise
        }
    }

    var sentIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return markedSent
    }

    var readOnDeviceIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return markedReadOnDevice
    }

    var results: [String] {
        lock.lock()
        defer { lock.unlock() }
        return exportResults
    }

    /// The `remoteName` each `sent` answer carried — what the core records.
    var sentRemoteNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return sentNames
    }
}

/// `luna.notifications` as 3A will serve it (§6.14). It records rather than posts.
final class FakePluginNotificationsBridge: PluginCapabilityInstalling, @unchecked Sendable {

    let capabilityName = PluginCapabilityName.notifications

    private let scheduler: PluginCallbackScheduling
    private let lock = NSLock()
    private(set) var posted: [[String: Any]] = []

    init(scheduler: PluginCallbackScheduling) { self.scheduler = scheduler }

    func install(into namespace: PluginCapabilityNamespace) {
        let outerContext = namespace.context
        let scheduler = self.scheduler
        let bridge = self
        let notifications = namespace.makeNamespaceObject()

        let post: @convention(block) (JSValue?) -> JSValue? = { value in
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            bridge.lock.lock()
            bridge.posted.append(PluginBridgeValue.dictionary(value))
            bridge.lock.unlock()
            box.fulfill(["posted": true])
            return promise
        }

        let clear: @convention(block) (JSValue?) -> JSValue? = { _ in
            let context = JSContext.current() ?? outerContext
            let (promise, box) = PluginPromiseBox.make(in: context, scheduler: scheduler)
            box.fulfill(NSNull())
            return promise
        }

        notifications.setObject(post, forKeyedSubscript: "post" as NSString)
        notifications.setObject(clear, forKeyedSubscript: "clear" as NSString)
        namespace.install(notifications, as: capabilityName.rawValue)
    }

    var postedTitles: [String] {
        lock.lock()
        defer { lock.unlock() }
        return posted.compactMap { $0["title"] as? String }
    }
}

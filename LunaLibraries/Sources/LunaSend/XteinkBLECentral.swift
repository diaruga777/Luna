//
//  XteinkBLECentral.swift
//  Luna
//

import CoreBluetooth
import CryptoKit
import Foundation
import LunaModels
import LunaStorage

/// Background-restorable CoreBluetooth central for the short X3 rendezvous.
///
/// iOS can restore this manager after ordinary suspension/termination when the
/// reader advertises, but cannot relaunch an app the user explicitly force-quit.
/// The X3 should advertise for a short window after a power-button wake so Luna
/// can reconnect without keeping a BLE link alive while CrossPoint renders EPUBs.
public final class XteinkBLECentral: NSObject, XteinkBLETransporting {
    public static let restorationIdentifier = "com.hsanabria.luna.xteink-central"
    public static let shared = XteinkBLECentral()

    private let queue = DispatchQueue(label: "com.hsanabria.luna.xteink.ble")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var control: CBCharacteristic?
    private var dataIn: CBCharacteristic?
    private var status: CBCharacteristic?
    private var pendingControl: (token: UInt64, operation: String, continuation: CheckedContinuation<Void, Error>)?
    /// Monotonic id for `pendingControl`, so a timed-out operation's deadline
    /// closure can never fail a LATER operation that reused the same name.
    private var controlToken: UInt64 = 0
    private var readyToWrite: CheckedContinuation<Void, Never>?
    /// One paced sender waiting for the reader's next durable-receipt
    /// checkpoint (see `XteinkTransferFlowControl`). Resumed by any status
    /// carrying `received`/`resume_offset`, failed by an error status, a
    /// dropped link, or `checkpointTimeout`.
    private var checkpointWaiter: (token: UInt64, continuation: CheckedContinuation<Void, Error>)?
    private var pendingWiFi: CheckedContinuation<XteinkWiFiOffer, Error>?
    private var active = false
    private var cancelling = false
    /// A pending connect to the known reader. CoreBluetooth keeps it open
    /// indefinitely and completes it the instant the reader advertises, so a
    /// wake window is never lost to a scan-discovery race. Retained because
    /// an unretained CBPeripheral cancels its own pending connect.
    private var standingConnect: CBPeripheral?
    /// Sticky for the current session once any status names a read-report
    /// window (`"win":"rr"`) — every status in such a window carries it, so
    /// one sighting is enough. Cleared on disconnect/session end.
    private var readReportOnlyWindow = false
    /// Last durable application checkpoint reported by the reader. A new
    /// `start_put` resumes from this offset after a link interruption.
    private var checkpoint = (offset: 0, sequence: UInt32(0))
    /// The reader's advertised confirmation stride ("ckpt"), for flow
    /// control. Falls back to the pre-field firmware's 8192 until a status
    /// carries it; reset per connection.
    private var checkpointIntervalBytes = XteinkTransferFlowControl.defaultCheckpointIntervalBytes
    private var nonce: String?
    private let pairingStore: any XteinkPairingStoring
    private let hostID: String
    private static let controlTimeout: TimeInterval = 15
    /// Generous next to the ~200 ms a checkpoint interval takes on a healthy
    /// link; only a wedged or silently-failed reader reaches it.
    private static let checkpointTimeout: TimeInterval = 10

    public override convenience init() {
        self.init(pairingStore: XteinkKeychainPairingStore(), hostID: "luna-ios")
    }

    public init(pairingStore: any XteinkPairingStoring, hostID: String) {
        self.pairingStore = pairingStore
        self.hostID = hostID
        super.init()
        central = CBCentralManager(
            delegate: self, queue: queue,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restorationIdentifier,
                      CBCentralManagerOptionShowPowerAlertKey: false])
    }

    public var isRendezvousActive: Bool { queue.sync { active && peripheral != nil && control != nil && dataIn != nil } }

    /// Whether the current rendezvous session is a read-report-only window —
    /// the device opened it purely to hand back finished-reading ids, and has
    /// no send capacity this session. Rendezvous-ready observers use this to
    /// skip the queued-send sweep and just answer `reportNoWork()`.
    public var isReadReportOnlyWindow: Bool { queue.sync { readReportOnlyWindow } }

    /// Settings' first-use pairing UI supplies the verified one-time secret.
    /// The subsequent `hello` reads it from the App-Group Keychain.
    public func savePairingSecret(_ secret: String) { pairingStore.save(secret, for: hostID) }
    public func forgetPairing() {
        pairingStore.removeCredential(for: hostID)
        XteinkSendSettings.pairedPeripheralID = nil
        queue.async { [weak self] in
            guard let self, let standing = self.standingConnect else { return }
            self.central.cancelPeripheralConnection(standing)
            self.standingConnect = nil
        }
    }
    /// Whether a pairing secret exists — the settings screen's paired badge.
    public var isPaired: Bool { pairingStore.credential(for: hostID) != nil }

    /// First-use settings UI calls this once AccessorySetupKit's system picker
    /// has bonded the reader over BLE. The hello carries no shared code — the
    /// bonded link is the proof of physical presence — and the reader returns
    /// `op_ack: hello` only after persisting the host.
    public func pair(pairSecret: String) async throws {
        guard isRendezvousActive else { throw XteinkSyncError.unavailable }
        try await sendControl("hello", values: [
            "host_id": hostID, "pair_secret": pairSecret,
        ])
        pairingStore.save(pairSecret, for: hostID)
    }

    /// Opens scanning proactively when the app is foregrounded. A restored
    /// manager receives the same path through `willRestoreState`.
    public func beginRendezvousScan() {
        queue.async { [weak self] in self?.scanIfReady() }
    }

    /// Connects to the accessory AccessorySetupKit's picker just authorized,
    /// bypassing the scan entirely. The system already resolved the identity;
    /// re-scanning would just wait to re-discover an advertisement it already
    /// found.
    public func connect(toPeripheralIdentifier identifier: UUID) {
        queue.async { [weak self] in
            guard let self, let match = self.central.retrievePeripherals(withIdentifiers: [identifier]).first
            else { return }
            self.central.stopScan()
            self.peripheral = match
            match.delegate = self
            self.central.connect(match)
        }
    }

    public func endRendezvous() {
        queue.async { [weak self] in
            guard let self else { return }
            self.central.stopScan()
            if let peripheral = self.peripheral { self.central.cancelPeripheralConnection(peripheral) }
            if let standing = self.standingConnect {
                self.central.cancelPeripheralConnection(standing)
                self.standingConnect = nil
            }
            self.clearConnection()
        }
    }

    public func send(
        _ epub: Data, fileName: String, title: String,
        articleID: UUID? = nil, queuedRemaining: Int? = nil,
        progress: @escaping @Sendable (XteinkSyncProgress) -> Void
    ) async throws {
        guard XteinkTransferSizePolicy().transport(forFinalXteinkEPUB: epub) == .bluetoothLowEnergy else {
            throw XteinkSyncError.protocolError("oversized BLE payload")
        }
        try Task.checkCancellation()
        guard isRendezvousActive else { throw XteinkSyncError.unavailable }
        let digest = SHA256.hash(data: epub).map { String(format: "%02x", $0) }.joined()
        try await authenticatedHello()
        let maximum = await maximumDataPayload()
        var startPutValues: [String: Any] = [
            "kind": "book", "name": fileName, "size": epub.count, "sha256": digest,
            "resume": true, "chunk_size": maximum,
        ]
        if let articleID { startPutValues["article_id"] = articleID.uuidString.lowercased() }
        if let queuedRemaining { startPutValues["queue_remaining"] = queuedRemaining }
        try await sendControl("start_put", values: startPutValues)

        let resume = await currentCheckpoint()
        var offset = min(resume.offset, epub.count)
        var sequence = resume.sequence
        while offset < epub.count {
            do { try Task.checkCancellation() } catch {
                try? await sendControl("cancel")
                throw XteinkSyncError.cancelled
            }
            while await shouldPauseForFlowControl(sentBytes: offset, totalBytes: epub.count) {
                try await waitForCheckpointAdvance()
            }
            let count = min(maximum, epub.count - offset)
            let frame = XteinkSyncProtocol.frame(
                sequence: sequence, payload: epub.subdata(in: offset..<(offset + count)))
            try await writeData(frame)
            offset += count
            sequence &+= 1
            progress(XteinkSyncProgress(completedBytes: offset, totalBytes: epub.count))
        }
        try await sendControl("commit", values: ["sha256": digest, "size": epub.count])
    }

    public func requestWiFi() async throws -> XteinkWiFiOffer {
        guard isRendezvousActive else { throw XteinkSyncError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { return continuation.resume(throwing: XteinkSyncError.unavailable) }
                self.pendingWiFi = continuation
                Task { [weak self] in
                    do { try await self?.sendControl("wifi_request", values: ["prefer_ap": true]) }
                    catch { self?.resumeWiFi(throwing: error) }
                }
            }
        }
    }

    /// A pending-delete drain can be the only thing a rendezvous does this
    /// session (no book to send), so this authenticates on its own rather
    /// than relying on `send`/`reportNoWork` having already done it.
    public func delete(remotePath: String) async throws {
        guard isRendezvousActive else { throw XteinkSyncError.unavailable }
        try await authenticatedHello()
        try await sendControl("delete", values: ["name": remotePath])
    }

    /// Ends a power-button rendezvous that found no queued reader work. This
    /// follows an authenticated hello so the X3 never honours an unauthenticated
    /// radio command.
    public func reportNoWork() async throws {
        guard isRendezvousActive else { throw XteinkSyncError.unavailable }
        try await authenticatedHello()
        try await sendControl("no_work")
    }


    private func maximumDataPayload() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                let limit = self?.peripheral?.maximumWriteValueLength(for: .withoutResponse) ?? 20
                continuation.resume(returning: max(1, limit - 4))
            }
        }
    }

    private func currentCheckpoint() async -> (offset: Int, sequence: UInt32) {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in continuation.resume(returning: self?.checkpoint ?? (0, 0)) }
        }
    }

    private func authenticatedHello() async throws {
        let (nonce, secret) = await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, let nonce = self.nonce,
                      let secret = self.pairingStore.credential(for: self.hostID) else {
                    return continuation.resume(returning: ("", ""))
                }
                continuation.resume(returning: (nonce, secret))
            }
        }
        guard !nonce.isEmpty, !secret.isEmpty else { throw XteinkSyncError.pairingRequired }
        let key = SymmetricKey(data: Data(secret.utf8))
        let message = Data("\(nonce)|\(hostID)|\(XteinkSyncProtocol.version)".utf8)
        let response = HMAC<SHA256>.authenticationCode(for: message, using: key)
            .map { String(format: "%02x", $0) }.joined()
        try await sendControl("hello", values: ["host_id": hostID, "response": response])
    }

    private func sendControl(_ operation: String, values: [String: Any] = [:]) async throws {
        let data = try XteinkSyncProtocol.controlData(operation, values: values)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self, let peripheral = self.peripheral, let control = self.control else {
                    return continuation.resume(throwing: XteinkSyncError.unavailable)
                }
                // One op_ack slot: overwriting an occupied slot would orphan
                // the earlier continuation, hanging its task forever. Callers
                // are serialized through `XteinkRendezvousTransferQueue`; this
                // turns any residual race into a visible failure instead.
                guard self.pendingControl == nil else {
                    return continuation.resume(throwing: XteinkSyncError.protocolError(
                        "control channel busy (\(self.pendingControl?.operation ?? "?") still pending)"))
                }
                self.controlToken &+= 1
                let token = self.controlToken
                self.pendingControl = (token, operation, continuation)
                peripheral.writeValue(data, for: control, type: .withResponse)
                self.queue.asyncAfter(deadline: .now() + Self.controlTimeout) { [weak self] in
                    guard let self, self.pendingControl?.token == token else { return }
                    let pending = self.pendingControl; self.pendingControl = nil
                    pending?.continuation.resume(throwing: XteinkSyncError.protocolError("timed out waiting for \(operation) ACK"))
                }
            }
        }
    }

    private func writeData(_ data: Data) async throws {
        try Task.checkCancellation()
        await waitUntilReadyToWrite()
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self, let peripheral = self.peripheral, let characteristic = self.dataIn else {
                    return continuation.resume(throwing: XteinkSyncError.unavailable)
                }
                // BLE write-without-response is link-layer reliable but not an
                // application acknowledgement. `commit` verifies the SHA-256.
                peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
                continuation.resume()
            }
        }
    }

    private func shouldPauseForFlowControl(sentBytes: Int, totalBytes: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { return continuation.resume(returning: false) }
                continuation.resume(returning: XteinkTransferFlowControl.shouldPause(
                    sentBytes: sentBytes, confirmedBytes: self.checkpoint.offset,
                    totalBytes: totalBytes,
                    checkpointIntervalBytes: self.checkpointIntervalBytes))
            }
        }
    }

    private func waitForCheckpointAdvance() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self, self.peripheral != nil else {
                    return continuation.resume(throwing: XteinkSyncError.unavailable)
                }
                guard self.checkpointWaiter == nil else {
                    return continuation.resume(throwing: XteinkSyncError.protocolError("checkpoint waiter busy"))
                }
                self.controlToken &+= 1
                let token = self.controlToken
                self.checkpointWaiter = (token, continuation)
                self.queue.asyncAfter(deadline: .now() + Self.checkpointTimeout) { [weak self] in
                    guard let self, self.checkpointWaiter?.token == token else { return }
                    let waiter = self.checkpointWaiter; self.checkpointWaiter = nil
                    waiter?.continuation.resume(throwing: XteinkSyncError.protocolError("timed out waiting for reader checkpoint"))
                }
            }
        }
    }

    private func resumeCheckpointWaiter(throwing error: Error? = nil) {
        let waiter = checkpointWaiter; checkpointWaiter = nil
        if let error {
            waiter?.continuation.resume(throwing: error)
        } else {
            waiter?.continuation.resume()
        }
    }

    private func waitUntilReadyToWrite() async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, let peripheral = self.peripheral, !peripheral.canSendWriteWithoutResponse else {
                    return continuation.resume()
                }
                self.readyToWrite = continuation
            }
        }
    }

    private func scanIfReady() {
        guard central.state == .poweredOn, peripheral == nil else { return }
        // The X3 stops advertising the moment ANY central holds its link —
        // including the sibling Luna app's central or a system-restored
        // connection — and a scan can never discover a connected peripheral.
        // Ask the system for it directly before falling back to a scan.
        if let connected = central.retrieveConnectedPeripherals(withServices: [XteinkSyncProtocol.service]).first {
            peripheral = connected
            connected.delegate = self
            central.connect(connected)
            return
        }
        // Standing connect to the known reader (see `standingConnect`). The
        // scan still runs alongside it, for a reader whose address changed or
        // that this install has never seen.
        if standingConnect == nil,
           let stored = XteinkSendSettings.pairedPeripheralID,
           let identifier = UUID(uuidString: stored),
           let known = central.retrievePeripherals(withIdentifiers: [identifier]).first {
            standingConnect = known
            known.delegate = self
            central.connect(known)
        }
        central.scanForPeripherals(withServices: [XteinkSyncProtocol.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func clearConnection() {
        active = false
        nonce = nil
        readReportOnlyWindow = false
        checkpointIntervalBytes = XteinkTransferFlowControl.defaultCheckpointIntervalBytes
        peripheral?.delegate = nil
        peripheral = nil; control = nil; dataIn = nil; status = nil
        pendingControl?.continuation.resume(throwing: XteinkSyncError.unavailable); pendingControl = nil
        resumeCheckpointWaiter(throwing: XteinkSyncError.unavailable)
        resumeWiFi(throwing: XteinkSyncError.unavailable)
        readyToWrite?.resume(); readyToWrite = nil
    }

    private func resumeWiFi(_ offer: XteinkWiFiOffer) {
        pendingWiFi?.resume(returning: offer); pendingWiFi = nil
    }
    private func resumeWiFi(throwing error: Error) {
        pendingWiFi?.resume(throwing: error); pendingWiFi = nil
    }
}

extension XteinkBLECentral: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) { scanIfReady() }
    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], let first = restored.first {
            peripheral = first; first.delegate = self
            central.connect(first)
        }
    }
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        self.peripheral = peripheral
        central.stopScan()
        peripheral.delegate = self
        central.connect(peripheral)
    }
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // The standing connect delivers here with `self.peripheral` still nil;
        // adopt whichever path won and retire the other.
        self.peripheral = peripheral
        peripheral.delegate = self
        if let standing = standingConnect, standing !== peripheral {
            central.cancelPeripheralConnection(standing)
        }
        standingConnect = nil
        central.stopScan()
        XteinkSendSettings.pairedPeripheralID = peripheral.identifier.uuidString
        peripheral.discoverServices([XteinkSyncProtocol.service])
    }
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        clearConnection()
        if !cancelling { scanIfReady() }
    }
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        clearConnection(); scanIfReady()
    }
}

extension XteinkBLECentral: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == XteinkSyncProtocol.service }) else { return clearConnection() }
        peripheral.discoverCharacteristics([XteinkSyncProtocol.control, XteinkSyncProtocol.dataIn, XteinkSyncProtocol.status, XteinkSyncProtocol.dataOut], for: service)
    }
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { return clearConnection() }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case XteinkSyncProtocol.control: control = characteristic
            case XteinkSyncProtocol.dataIn: dataIn = characteristic
            case XteinkSyncProtocol.status: status = characteristic
            default: break
            }
        }
        active = control != nil && dataIn != nil && status != nil
        if let status { peripheral.setNotifyValue(true, for: status) }
    }
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == XteinkSyncProtocol.control else { return }
        // A successful GATT write merely says that the reader accepted bytes.
        // Completion is the matching `op_ack` status notification below.
        if let error {
            let pending = pendingControl; pendingControl = nil
            pending?.continuation.resume(throwing: error)
        }
    }
    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == XteinkSyncProtocol.status, error == nil, characteristic.isNotifying else { return }
        // The X3's initial nonce may have been emitted before iOS subscribed.
        // An explicit read makes pairing deterministic after every reconnect.
        peripheral.readValue(for: characteristic)
    }
    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        let continuation = readyToWrite; readyToWrite = nil; continuation?.resume()
    }
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == XteinkSyncProtocol.status, error == nil,
              let data = characteristic.value,
              let status = XteinkStatusMessage.parse(data)
        else { return }
        // `win` gates whether the rendezvous-ready observer sweeps queued
        // sends, so it must land before that observer can fire off `nonce`.
        if status.isReadReportWindow { readReportOnlyWindow = true }
        if let initialNonce = status.nonce {
            // The reader repeats the (constant per-connection) nonce in every
            // transfer status, so ready must post only on the FIRST sighting —
            // one sweep per rendezvous. `clearConnection` resets the nonce, so
            // a reconnect inside the same reader window posts again.
            let firstNonceThisConnection = nonce == nil
            nonce = initialNonce
            if firstNonceThisConnection {
                SharedDiagnosticLog.record(
                    readReportOnlyWindow
                        ? "Rendezvous ready (read-report window)" : "Rendezvous ready",
                    category: "xteink")
                DispatchQueue.main.async { NotificationCenter.default.post(name: .xteinkRendezvousReady, object: self) }
            }
        }
        if let received = status.received { checkpoint.offset = received }
        if let offset = status.resumeOffset { checkpoint.offset = offset }
        if let next = status.nextSequence { checkpoint.sequence = next }
        if let interval = status.checkpointIntervalBytes, interval > 0 {
            checkpointIntervalBytes = interval
        }
        if status.isFailure {
            let errorMessage = status.error ?? "reader rejected operation"
            let pending = pendingControl; pendingControl = nil
            pending?.continuation.resume(throwing: XteinkSyncError.protocolError(errorMessage))
            resumeCheckpointWaiter(throwing: XteinkSyncError.protocolError(errorMessage))
            resumeWiFi(throwing: XteinkSyncError.protocolError(errorMessage))
            return
        }
        // Every non-failure status carries the reader's durable offset, so
        // any of them can release a sender paused on flow control.
        if status.received != nil || status.resumeOffset != nil {
            resumeCheckpointWaiter()
        }
        if let ack = status.opAck, pendingControl?.operation == ack {
            let pending = pendingControl; pendingControl = nil
            pending?.continuation.resume()
        }
        if let wifi = status.wifi {
            resumeWiFi(wifi)
        }
        if !status.readIDs.isEmpty {
            handleReadIDs(status.readIDs)
        }
    }

    /// The device is handing back finished-reading ids. Luna marks each save
    /// read locally, then fires the ack as a plain GATT write — NOT through
    /// `sendControl`'s `pendingControl` slot, which a concurrent sweep
    /// operation may already own.
    private func handleReadIDs(_ ids: [UUID]) {
        SharedDiagnosticLog.record("Reader reported \(ids.count) finished book(s)", category: "xteink")
        for id in ids { SavesStore.shared.markRemoteDeliveryReadOnDevice(for: id, destination: ArticleDestinationID.xteink) }
        for id in ids { SavesStore.shared.markFinishedReading(id) }
        guard let data = try? XteinkSyncProtocol.controlData(
            "read_ack", values: ["ids": ids.map { $0.uuidString.lowercased() }])
        else { return }
        queue.async { [weak self] in
            guard let self, let peripheral = self.peripheral, let control = self.control else { return }
            peripheral.writeValue(data, for: control, type: .withResponse)
        }
    }
}

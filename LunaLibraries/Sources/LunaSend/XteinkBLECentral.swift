//
//  XteinkBLECentral.swift
//  Luna
//

import CoreBluetooth
import CryptoKit
import Foundation

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
    private var pendingControl: (operation: String, continuation: CheckedContinuation<Void, Error>)?
    private var readyToWrite: CheckedContinuation<Void, Never>?
    private var pendingWiFi: CheckedContinuation<XteinkWiFiOffer, Error>?
    private var active = false
    private var cancelling = false
    /// Last durable application checkpoint reported by the reader. A new
    /// `start_put` resumes from this offset after a link interruption.
    private var checkpoint = (offset: 0, sequence: UInt32(0))
    private var nonce: String?
    private let pairingStore: any XteinkPairingStoring
    private let hostID: String
    private static let controlTimeout: TimeInterval = 15

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

    /// Settings' first-use pairing UI supplies the verified one-time secret.
    /// The subsequent `hello` reads it from the App-Group Keychain.
    public func savePairingSecret(_ secret: String) { pairingStore.save(secret, for: hostID) }
    public func forgetPairing() { pairingStore.removeCredential(for: hostID) }

    /// First-use settings UI calls this while the X3 shows its short pairing
    /// code. The reader returns `op_ack: hello` only after persisting the host.
    public func pair(code: String, pairSecret: String) async throws {
        guard isRendezvousActive else { throw XteinkSyncError.unavailable }
        try await sendControl("hello", values: [
            "host_id": hostID, "code": code, "pair_secret": pairSecret,
        ])
        pairingStore.save(pairSecret, for: hostID)
    }

    /// Opens scanning proactively when the app is foregrounded. A restored
    /// manager receives the same path through `willRestoreState`.
    public func beginRendezvousScan() {
        queue.async { [weak self] in self?.scanIfReady() }
    }

    public func endRendezvous() {
        queue.async { [weak self] in
            guard let self else { return }
            self.central.stopScan()
            if let peripheral = self.peripheral { self.central.cancelPeripheralConnection(peripheral) }
            self.clearConnection()
        }
    }

    public func send(
        _ epub: Data, fileName: String, title: String,
        progress: @escaping @Sendable (XteinkSyncProgress) -> Void
    ) async throws {
        guard epub.count <= XteinkSyncProtocol.maximumBLEPayloadBytes else {
            throw XteinkSyncError.protocolError("oversized BLE payload")
        }
        try Task.checkCancellation()
        guard isRendezvousActive else { throw XteinkSyncError.unavailable }
        let digest = SHA256.hash(data: epub).map { String(format: "%02x", $0) }.joined()
        try await authenticatedHello()
        try await sendControl("start_put", values: [
            "kind": "book", "name": fileName, "size": epub.count, "sha256": digest,
            "resume": 0,
        ])

        let maximum = await maximumDataPayload()
        let resume = await currentCheckpoint()
        var offset = min(resume.offset, epub.count)
        var sequence = resume.sequence
        while offset < epub.count {
            do { try Task.checkCancellation() } catch {
                try? await sendControl("cancel")
                throw XteinkSyncError.cancelled
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
                    do { try await self?.sendControl("wifi_request") }
                    catch { self?.resumeWiFi(throwing: error) }
                }
            }
        }
    }

    public func delete(remotePath: String) async throws {
        guard isRendezvousActive else { throw XteinkSyncError.unavailable }
        try await sendControl("delete", values: ["name": remotePath])
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
                self.pendingControl = (operation, continuation)
                peripheral.writeValue(data, for: control, type: .withResponse)
                self.queue.asyncAfter(deadline: .now() + Self.controlTimeout) { [weak self] in
                    guard let self, self.pendingControl?.operation == operation else { return }
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
        central.scanForPeripherals(withServices: [XteinkSyncProtocol.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func clearConnection() {
        active = false
        nonce = nil
        peripheral?.delegate = nil
        peripheral = nil; control = nil; dataIn = nil; status = nil
        pendingControl?.continuation.resume(throwing: XteinkSyncError.unavailable); pendingControl = nil
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
            case XteinkSyncProtocol.status: status = characteristic; peripheral.setNotifyValue(true, for: characteristic)
            default: break
            }
        }
        active = control != nil && dataIn != nil && status != nil
        if active { DispatchQueue.main.async { NotificationCenter.default.post(name: .xteinkRendezvousReady, object: self) } }
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
    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        let continuation = readyToWrite; readyToWrite = nil; continuation?.resume()
    }
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == XteinkSyncProtocol.status, error == nil,
              let data = characteristic.value,
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if let initialNonce = status["nonce"] as? String { nonce = initialNonce }
        if let received = status["received"] as? Int { checkpoint.offset = received }
        if let offset = status["resume_offset"] as? Int { checkpoint.offset = offset }
        if let next = status["next_sequence"] as? Int { checkpoint.sequence = UInt32(clamping: next) }
        if let errorMessage = status["error"] as? String {
            let pending = pendingControl; pendingControl = nil
            pending?.continuation.resume(throwing: XteinkSyncError.protocolError(errorMessage))
            resumeWiFi(throwing: XteinkSyncError.protocolError(errorMessage))
            return
        }
        if let ack = status["op_ack"] as? String, pendingControl?.operation == ack {
            let pending = pendingControl; pendingControl = nil
            pending?.continuation.resume()
        }
        if let wifi = status["wifi"] as? [String: Any], let mode = wifi["mode"] as? String,
           let offerMode = XteinkWiFiOffer.Mode(rawValue: mode), let ip = wifi["ip"] as? String {
            resumeWiFi(XteinkWiFiOffer(mode: offerMode, ssid: wifi["ssid"] as? String ?? "",
                                       passphrase: wifi["password"] as? String ?? "", host: ip))
        }
    }
}

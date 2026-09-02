//
//  CoreBluetoothPluginTransport.swift
//  LunaPluginTransport
//

import CoreBluetooth
import Foundation

/// `PluginBluetoothTransporting` over CoreBluetooth, one per declaring plugin.
///
/// The manager carries the restoration identifier `plugin.<id>` and the app's
/// `bluetooth-central` background mode, so iOS can restore it after ordinary
/// suspension or termination when the peripheral advertises again. It cannot
/// relaunch an app the user force-quit.
///
/// Everything runs on this transport's own queue. The manager is nil only while
/// AccessorySetupKit's picker is on screen: the picker refuses to appear while
/// the process holds any live `CBManager` once the app has the global Bluetooth
/// permission (ASErrorDomain 550).
public final class CoreBluetoothPluginTransport: NSObject, PluginBluetoothTransporting {

    public weak var transportDelegate: PluginBluetoothTransportDelegate?

    private let restorationIdentifier: String
    private let queue: DispatchQueue
    private var manager: CBCentralManager?
    private var peripherals: [String: CBPeripheral] = [:]
    /// Retained so a pending connect survives; an unretained `CBPeripheral`
    /// cancels its own.
    private var standing: [String: CBPeripheral] = [:]
    private var characteristics: [String: [String: CBCharacteristic]] = [:]
    private var scanServices: [String] = []
    /// Connects asked for while the manager was down or not yet powered on.
    private var parkedConnects: Set<String> = []

    private var pendingDiscovers: [String: [(Result<[String], PluginTransportError>) -> Void]] = [:]
    private var pendingReads: [String: (Result<String, PluginTransportError>) -> Void] = [:]
    private var pendingWrites: [String: (Result<Void, PluginTransportError>) -> Void] = [:]
    private var pendingSubscribes: [String: (Result<Void, PluginTransportError>) -> Void] = [:]

    public init(pluginID: String) {
        restorationIdentifier = "plugin.\(pluginID)"
        queue = DispatchQueue(label: "com.hsanabria.luna.pluginBluetooth.\(pluginID)")
        super.init()
        queue.setSpecific(key: Self.queueKey, value: true)
        queue.async { [self] in manager = makeManager() }
    }

    private static let queueKey = DispatchSpecificKey<Bool>()

    /// Runs `work` on the manager's queue, or straight away when already on it.
    ///
    /// A CoreBluetooth delegate callback arrives ON that queue and the center
    /// reads the transport from it — a session is built inside `didConnect`,
    /// and the state is read inside `didUpdateState`. A plain `queue.sync`
    /// there deadlocks against itself.
    private func onQueue<T>(_ work: () -> T) -> T {
        guard DispatchQueue.getSpecific(key: Self.queueKey) == nil else { return work() }
        return queue.sync(execute: work)
    }

    private func makeManager() -> CBCentralManager {
        CBCentralManager(
            delegate: self, queue: queue,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: restorationIdentifier,
                CBCentralManagerOptionShowPowerAlertKey: false,
            ])
    }

    public var state: PluginBluetoothState {
        onQueue {
            switch manager?.state {
            case .poweredOn: return .poweredOn
            case .poweredOff: return .poweredOff
            case .unauthorized: return .unauthorized
            case .unsupported: return .unsupported
            default: return .unknown
            }
        }
    }

    // MARK: - Scanning and connecting

    public func startScan(services: [String]) {
        queue.async { [self] in
            scanServices = services
            guard let manager, manager.state == .poweredOn else { return }
            let uuids = services.compactMap(Self.uuid(from:))
            guard !uuids.isEmpty else { return }
            // A peripheral another process (or the system) already holds has
            // stopped advertising, and a scan can never discover it. Ask the
            // system for it directly first.
            for peripheral in manager.retrieveConnectedPeripherals(withServices: uuids) {
                adopt(peripheral)
                manager.connect(peripheral)
            }
            manager.scanForPeripherals(
                withServices: uuids,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }

    public func stopScan() {
        queue.async { [self] in manager?.stopScan() }
    }

    public func connect(deviceID: String) {
        queue.async { [self] in
            guard let manager, manager.state == .poweredOn,
                  let identifier = UUID(uuidString: deviceID),
                  let match = manager.retrievePeripherals(withIdentifiers: [identifier]).first
            else {
                parkedConnects.insert(deviceID)
                return
            }
            adopt(match)
            standing[deviceID] = match
            manager.connect(match)
        }
    }

    public func cancelConnection(deviceID: String) {
        queue.async { [self] in
            if let peripheral = peripherals[deviceID] {
                manager?.cancelPeripheralConnection(peripheral)
            }
            if let pending = standing.removeValue(forKey: deviceID) {
                manager?.cancelPeripheralConnection(pending)
            }
        }
    }

    public func knownDevices(ids: [String]) -> [PluginBluetoothDevice] {
        onQueue {
            let identifiers = ids.compactMap(UUID.init(uuidString:))
            guard !identifiers.isEmpty, let manager else { return [] }
            return manager.retrievePeripherals(withIdentifiers: identifiers).map(Self.device(from:))
        }
    }

    // MARK: - GATT

    public func discover(
        serviceUUID: String, deviceID: String,
        completion: @escaping (Result<[String], PluginTransportError>) -> Void
    ) {
        queue.async { [self] in
            guard let peripheral = peripherals[deviceID], let uuid = Self.uuid(from: serviceUUID)
            else { return completion(.failure(.disconnected)) }
            pendingDiscovers[serviceUUID, default: []].append(completion)
            if let service = peripheral.services?.first(where: { $0.uuid == uuid }) {
                peripheral.discoverCharacteristics(nil, for: service)
            } else {
                peripheral.discoverServices([uuid])
            }
        }
    }

    public func read(
        characteristicUUID: String, deviceID: String,
        completion: @escaping (Result<String, PluginTransportError>) -> Void
    ) {
        queue.async { [self] in
            guard let peripheral = peripherals[deviceID],
                  let characteristic = characteristics[deviceID]?[PluginBluetoothUUID.key(characteristicUUID)]
            else { return completion(.failure(.unavailable("no such characteristic"))) }
            guard pendingReads[PluginBluetoothUUID.key(characteristicUUID)] == nil else {
                return completion(.failure(.unavailable("a read on that characteristic is in flight")))
            }
            pendingReads[PluginBluetoothUUID.key(characteristicUUID)] = completion
            peripheral.readValue(for: characteristic)
        }
    }

    public func write(
        base64: String, characteristicUUID: String, deviceID: String, withResponse: Bool,
        completion: @escaping (Result<Void, PluginTransportError>) -> Void
    ) {
        queue.async { [self] in
            guard let data = Data(base64Encoded: base64) else {
                return completion(.failure(PluginTransportError(
                    code: "bad-argument", message: "the payload is not base64")))
            }
            guard let peripheral = peripherals[deviceID],
                  let characteristic = characteristics[deviceID]?[PluginBluetoothUUID.key(characteristicUUID)]
            else { return completion(.failure(.unavailable("no such characteristic"))) }
            guard withResponse else {
                peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
                return completion(.success(()))
            }
            guard pendingWrites[PluginBluetoothUUID.key(characteristicUUID)] == nil else {
                return completion(.failure(.unavailable("a write on that characteristic is in flight")))
            }
            pendingWrites[PluginBluetoothUUID.key(characteristicUUID)] = completion
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        }
    }

    public func subscribe(
        characteristicUUID: String, deviceID: String,
        completion: @escaping (Result<Void, PluginTransportError>) -> Void
    ) {
        queue.async { [self] in
            guard let peripheral = peripherals[deviceID],
                  let characteristic = characteristics[deviceID]?[PluginBluetoothUUID.key(characteristicUUID)]
            else { return completion(.failure(.unavailable("no such characteristic"))) }
            guard !characteristic.isNotifying else { return completion(.success(())) }
            pendingSubscribes[PluginBluetoothUUID.key(characteristicUUID)] = completion
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    public func maximumWriteLength(deviceID: String) -> Int {
        onQueue {
            peripherals[deviceID]?.maximumWriteValueLength(for: .withoutResponse) ?? 20
        }
    }

    public func canWriteWithoutResponse(deviceID: String) -> Bool {
        onQueue { peripherals[deviceID]?.canSendWriteWithoutResponse ?? false }
    }

    // MARK: - The accessory picker

    public func releaseForAccessoryPicker(completion: @escaping () -> Void) {
        queue.async { [self] in
            defer { completion() }
            guard let manager else { return }
            manager.stopScan()
            for peripheral in peripherals.values { manager.cancelPeripheralConnection(peripheral) }
            for peripheral in standing.values { manager.cancelPeripheralConnection(peripheral) }
            standing = [:]
            peripherals = [:]
            characteristics = [:]
            manager.delegate = nil
            self.manager = nil
        }
    }

    public func rebuildAfterAccessoryPicker() {
        queue.async { [self] in
            guard manager == nil else { return }
            manager = makeManager()
        }
    }

    // MARK: - Helpers

    private func adopt(_ peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripherals[peripheral.identifier.uuidString] = peripheral
    }

    /// A `CBUUID` from a 16-, 32- or 128-bit hex spelling. `CBUUID(string:)`
    /// raises on anything else, and a manifest is user input.
    static func uuid(from text: String) -> CBUUID? {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "{} \n\t"))
        let hex = trimmed.replacingOccurrences(of: "-", with: "")
        let lengths = [4, 8, 32]
        guard lengths.contains(hex.count),
              hex.allSatisfy({ $0.isHexDigit })
        else { return nil }
        return CBUUID(string: trimmed)
    }

    static func device(from peripheral: CBPeripheral) -> PluginBluetoothDevice {
        PluginBluetoothDevice(
            id: peripheral.identifier.uuidString, name: peripheral.name,
            serviceUUIDs: (peripheral.services ?? []).map(\.uuid.uuidString))
    }

    private func failPending(_ error: PluginTransportError) {
        let discovers = pendingDiscovers.values.flatMap { $0 }
        pendingDiscovers = [:]
        let reads = pendingReads.values
        pendingReads = [:]
        let writes = pendingWrites.values
        pendingWrites = [:]
        let subscribes = pendingSubscribes.values
        pendingSubscribes = [:]
        for completion in discovers { completion(.failure(error)) }
        for completion in reads { completion(.failure(error)) }
        for completion in writes { completion(.failure(error)) }
        for completion in subscribes { completion(.failure(error)) }
    }
}

extension CoreBluetoothPluginTransport: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let parked = parkedConnects
        parkedConnects = []
        transportDelegate?.bluetoothTransportDidChangeState(state)
        guard central.state == .poweredOn else { return }
        for deviceID in parked { connect(deviceID: deviceID) }
    }

    public func centralManager(
        _ central: CBCentralManager, willRestoreState dict: [String: Any]
    ) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        for peripheral in restored {
            adopt(peripheral)
            central.connect(peripheral)
        }
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        adopt(peripheral)
        central.stopScan()
        central.connect(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        adopt(peripheral)
        let deviceID = peripheral.identifier.uuidString
        // The standing connect and the scan can both be open; retire the one
        // that lost.
        if let pending = standing.removeValue(forKey: deviceID), pending !== peripheral {
            central.cancelPeripheralConnection(pending)
        }
        central.stopScan()
        transportDelegate?.bluetoothTransportDidConnect(
            Self.device(from: peripheral), restored: false)
    }

    public func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let deviceID = peripheral.identifier.uuidString
        peripherals[deviceID] = nil
        characteristics[deviceID] = nil
        failPending(.disconnected)
        transportDelegate?.bluetoothTransportDidDisconnect(
            Self.device(from: peripheral), error: error?.localizedDescription)
    }

    public func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        let deviceID = peripheral.identifier.uuidString
        peripherals[deviceID] = nil
        standing[deviceID] = nil
        failPending(.unavailable(error?.localizedDescription ?? "the connect failed"))
        transportDelegate?.bluetoothTransportDidDisconnect(
            Self.device(from: peripheral), error: error?.localizedDescription)
    }
}

extension CoreBluetoothPluginTransport: CBPeripheralDelegate {

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { return failPending(.unavailable("\(error!)")) }
        for service in peripheral.services ?? [] {
            guard pendingDiscovers[service.uuid.uuidString] != nil
                || pendingDiscovers.keys.contains(where: {
                    Self.uuid(from: $0) == service.uuid
                })
            else { continue }
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        let deviceID = peripheral.identifier.uuidString
        var table = characteristics[deviceID] ?? [:]
        for characteristic in service.characteristics ?? [] {
            table[PluginBluetoothUUID.key(characteristic.uuid.uuidString)] = characteristic
        }
        characteristics[deviceID] = table
        let requested = pendingDiscovers.keys.filter { Self.uuid(from: $0) == service.uuid }
        for key in requested {
            let waiters = pendingDiscovers.removeValue(forKey: key) ?? []
            let result: Result<[String], PluginTransportError> = error == nil
                ? .success((service.characteristics ?? [])
                    .map { PluginBluetoothUUID.key($0.uuid.uuidString) })
                : .failure(.unavailable("\(error!)"))
            for completion in waiters { completion(result) }
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let key = PluginBluetoothUUID.key(characteristic.uuid.uuidString)
        guard let completion = pendingWrites.removeValue(forKey: key) else { return }
        completion(error == nil ? .success(()) : .failure(.unavailable("\(error!)")))
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
    ) {
        let key = PluginBluetoothUUID.key(characteristic.uuid.uuidString)
        guard let completion = pendingSubscribes.removeValue(forKey: key) else { return }
        completion(error == nil ? .success(()) : .failure(.unavailable("\(error!)")))
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let key = PluginBluetoothUUID.key(characteristic.uuid.uuidString)
        let base64 = (characteristic.value ?? Data()).base64EncodedString()
        // One callback serves both a read and a notification. A pending read
        // owns this value; anything else is the peripheral publishing.
        if let completion = pendingReads.removeValue(forKey: key) {
            completion(error == nil ? .success(base64) : .failure(.unavailable("\(error!)")))
            return
        }
        guard error == nil else { return }
        transportDelegate?.bluetoothTransport(
            didReceive: base64, characteristicUUID: key,
            deviceID: peripheral.identifier.uuidString)
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        transportDelegate?.bluetoothTransportIsReadyToWrite(
            deviceID: peripheral.identifier.uuidString)
    }
}

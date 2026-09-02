//
//  PluginBluetoothFakes.swift
//  LunaTests
//

import Foundation
import LunaPluginKit
import LunaPluginTransport
import LunaStorage

/// A radio a test drives by hand. Every call is recorded in order, so a test
/// asserts on what the center ASKED the transport for, not only on the answer.
final class FakePluginBluetoothTransport: PluginBluetoothTransporting, @unchecked Sendable {

    weak var transportDelegate: PluginBluetoothTransportDelegate?

    var state: PluginBluetoothState = .poweredOn
    var writeLength = 180
    var canWrite = true
    /// Characteristic UUIDs `discover` answers with.
    var characteristics: [String] = []
    var readAnswers: [String: Result<String, PluginTransportError>] = [:]

    /// While true a read parks until `answerRead` releases it, so a test can
    /// watch a second call wait its turn.
    var defersReads = false

    private let lock = NSLock()
    private(set) var calls: [String] = []
    private(set) var writes: [(characteristic: String, base64: String, withResponse: Bool)] = []
    private var parkedReads: [(Result<String, PluginTransportError>) -> Void] = []

    /// Adds one line to the ordered log. The pairing fake writes here too, so
    /// the pair flow's release/picker/rebuild order is one sequence.
    func note(_ call: String) {
        lock.lock()
        calls.append(call)
        lock.unlock()
    }

    private func record(_ call: String) { note(call) }

    func startScan(services: [String]) { record("startScan(\(services.joined(separator: ",")))") }
    func stopScan() { record("stopScan") }
    func connect(deviceID: String) { record("connect(\(deviceID))") }
    func cancelConnection(deviceID: String) { record("cancel(\(deviceID))") }

    func knownDevices(ids: [String]) -> [PluginBluetoothDevice] {
        ids.map { PluginBluetoothDevice(id: $0, name: "Reader", serviceUUIDs: []) }
    }

    func discover(
        serviceUUID: String, deviceID: String,
        completion: @escaping (Result<[String], PluginTransportError>) -> Void
    ) {
        record("discover(\(serviceUUID))")
        completion(.success(characteristics))
    }

    func read(
        characteristicUUID: String, deviceID: String,
        completion: @escaping (Result<String, PluginTransportError>) -> Void
    ) {
        record("read(\(characteristicUUID))")
        guard defersReads else {
            return completion(readAnswers[characteristicUUID] ?? .success(""))
        }
        lock.lock()
        parkedReads.append(completion)
        lock.unlock()
    }

    /// Answers the oldest parked read.
    func answerRead(_ base64: String) {
        lock.lock()
        let completion = parkedReads.isEmpty ? nil : parkedReads.removeFirst()
        lock.unlock()
        completion?(.success(base64))
    }

    var parkedReadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return parkedReads.count
    }

    func write(
        base64: String, characteristicUUID: String, deviceID: String, withResponse: Bool,
        completion: @escaping (Result<Void, PluginTransportError>) -> Void
    ) {
        lock.lock()
        writes.append((characteristicUUID, base64, withResponse))
        calls.append("write(\(characteristicUUID),response:\(withResponse))")
        lock.unlock()
        guard withResponse else { return completion(.success(())) }
        completion(.success(()))
    }

    func subscribe(
        characteristicUUID: String, deviceID: String,
        completion: @escaping (Result<Void, PluginTransportError>) -> Void
    ) {
        record("subscribe(\(characteristicUUID))")
        completion(.success(()))
    }

    func maximumWriteLength(deviceID: String) -> Int { writeLength }
    func canWriteWithoutResponse(deviceID: String) -> Bool { canWrite }

    func releaseForAccessoryPicker(completion: @escaping () -> Void) {
        record("release")
        completion()
    }

    func rebuildAfterAccessoryPicker() { record("rebuild") }

    // MARK: - Driving the delegate

    func fireConnect(_ device: PluginBluetoothDevice, restored: Bool = false) {
        transportDelegate?.bluetoothTransportDidConnect(device, restored: restored)
    }

    func fireDisconnect(_ device: PluginBluetoothDevice, error: String? = nil) {
        transportDelegate?.bluetoothTransportDidDisconnect(device, error: error)
    }

    func fireNotification(_ base64: String, characteristicUUID: String, deviceID: String) {
        transportDelegate?.bluetoothTransport(
            didReceive: base64, characteristicUUID: characteristicUUID, deviceID: deviceID)
    }

    func fireReadyToWrite(deviceID: String) {
        transportDelegate?.bluetoothTransportIsReadyToWrite(deviceID: deviceID)
    }
}

/// A picker that answers whatever the test set, recording into the transport's
/// own call list so the pair flow's ORDER is one sequence.
final class FakePluginAccessoryPairing: PluginAccessoryPairing, @unchecked Sendable {

    var answer: Result<PluginBluetoothDevice?, PluginTransportError> = .success(nil)
    private let transport: FakePluginBluetoothTransport
    private let lock = NSLock()
    private(set) var removedAccessories: [String] = []

    init(transport: FakePluginBluetoothTransport) { self.transport = transport }

    func showPicker(
        serviceUUIDs: [String], displayName: String,
        completion: @escaping (Result<PluginBluetoothDevice?, PluginTransportError>) -> Void
    ) {
        transport.note("showPicker")
        completion(answer)
    }

    func removeSetUpAccessories(completion: @escaping () -> Void) {
        transport.note("removeSetUpAccessories")
        completion()
    }

    func removeAccessory(deviceID: String, completion: @escaping () -> Void) {
        lock.lock()
        removedAccessories.append(deviceID)
        lock.unlock()
        completion()
    }
}

/// A background lease that records its begin/end pairs.
final class FakePluginBackgroundLease: PluginBackgroundLeasing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var begun: [String] = []
    private(set) var ended: [Int] = []
    private var next = 0

    func beginLease(name: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        next += 1
        begun.append(name)
        return next
    }

    func endLease(_ token: Int) {
        lock.lock()
        ended.append(token)
        lock.unlock()
    }

    var isBalanced: Bool {
        lock.lock()
        defer { lock.unlock() }
        return begun.count == ended.count
    }
}

/// The four witnesses a center needs, all fakes.
final class FakePluginTransportMaker: PluginTransportMaking, @unchecked Sendable {

    let transport: FakePluginBluetoothTransport
    let pairing: FakePluginAccessoryPairing
    let lease = FakePluginBackgroundLease()
    let lockFileURL: URL
    private let serviceLock: BluetoothServiceLock

    init(lockFileURL: URL) {
        transport = FakePluginBluetoothTransport()
        pairing = FakePluginAccessoryPairing(transport: transport)
        self.lockFileURL = lockFileURL
        serviceLock = BluetoothServiceLock(fileURL: lockFileURL)
    }

    func makeTransport(pluginID: String) -> any PluginBluetoothTransporting { transport }
    func makePairing(pluginID: String) -> (any PluginAccessoryPairing)? { pairing }
    func makeServiceLock(serviceUUID: String) -> BluetoothServiceLock { serviceLock }
    func makeLease() -> (any PluginBackgroundLeasing)? { lease }
}

/// Records every hook call, and reports whether the service lock was held
/// while the hook ran — the §10.4 invariant a test cannot see any other way.
final class RecordingPluginInvoker: PluginHookInvoking, @unchecked Sendable {

    private struct Box<T: Decodable>: Decodable { let value: T }

    private let lock = NSLock()
    private(set) var invocations: [(hook: PluginHook, pluginID: String, argumentJSON: String)] = []
    /// For each invocation, whether a rival process could have taken the lock.
    private(set) var lockWasFreeDuringHook: [Bool] = []
    /// Nil means the test does not care about the lock.
    var rivalLockFileURL: URL?
    /// Held before answering, so a test can watch the lock while a hook runs.
    var hookDuration: TimeInterval = 0

    var loadedPlugins: [PluginSummary] = []
    var disabledPlugins: [String: String] = [:]

    func matchedPlugins(forHost host: String) -> [PluginSummary] { loadedPlugins }
    func reloadAll() {}

    func invoke<T: Decodable>(
        _ hook: PluginHook, pluginID: String, argument: Encodable,
        timeout: TimeInterval, decode: T.Type
    ) async -> Result<T, PluginInvocationFailure> {
        let json = (try? JSONEncoder().encode(AnyEncodable(argument)))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        var lockWasFree = false
        if let rivalLockFileURL {
            let rival = BluetoothServiceLock(fileURL: rivalLockFileURL)
            lockWasFree = rival.acquire()
            if lockWasFree { rival.release() }
        }
        lock.lock()
        invocations.append((hook, pluginID, json))
        lockWasFreeDuringHook.append(lockWasFree)
        lock.unlock()
        if hookDuration > 0 {
            try? await Task.sleep(nanoseconds: UInt64(hookDuration * 1_000_000_000))
        }
        guard let boxed = try? JSONDecoder().decode(
            Box<T>.self, from: Data("{\"value\":null}".utf8))
        else { return .failure(.malformedResult("the fake cannot build \(T.self)")) }
        return .success(boxed.value)
    }

    var hooks: [PluginHook] {
        lock.lock()
        defer { lock.unlock() }
        return invocations.map(\.hook)
    }

    var eventTypes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return invocations.compactMap { invocation in
            guard let data = invocation.argumentJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return object["type"] as? String
        }
    }

    private struct AnyEncodable: Encodable {
        let wrapped: Encodable
        init(_ wrapped: Encodable) { self.wrapped = wrapped }
        func encode(to encoder: Encoder) throws { try wrapped.encode(to: encoder) }
    }
}

/// A Wi-Fi stack a test drives.
final class FakePluginWiFiJoiner: PluginWiFiJoining, @unchecked Sendable {
    var isForeground = true
    var joinResult: Result<Void, PluginTransportError> = .success(())
    var reachable = true

    private let lock = NSLock()
    private(set) var joined: [(ssid: String, passphrase: String?, joinOnce: Bool)] = []
    private(set) var forgotten: [String] = []
    private(set) var probes: [(host: String, port: Int)] = []

    func join(
        ssid: String, passphrase: String?, joinOnce: Bool,
        completion: @escaping (Result<Void, PluginTransportError>) -> Void
    ) {
        lock.lock()
        joined.append((ssid, passphrase, joinOnce))
        lock.unlock()
        completion(joinResult)
    }

    func forget(ssid: String) {
        lock.lock()
        forgotten.append(ssid)
        lock.unlock()
    }

    func isReachable(
        host: String, port: Int, timeout: TimeInterval,
        completion: @escaping (Bool) -> Void
    ) {
        lock.lock()
        probes.append((host, port))
        lock.unlock()
        completion(reachable)
    }
}

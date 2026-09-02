//
//  PluginBluetoothCenter.swift
//  LunaPluginTransport
//

import Foundation
import LunaPluginKit
import LunaPluginRuntime
import LunaStorage

/// One `onBluetooth` event, as the hook's argument (§10.1).
struct PluginBluetoothEvent: Encodable {
    let type: String
    let device: PluginBluetoothDevice?
    let restored: Bool?
    let error: String?
    let state: String?

    static func connected(_ device: PluginBluetoothDevice, restored: Bool) -> Self {
        Self(type: "connected", device: device, restored: restored, error: nil, state: nil)
    }
    static func disconnected(_ device: PluginBluetoothDevice, error: String?) -> Self {
        Self(type: "disconnected", device: device, restored: nil, error: error, state: nil)
    }
    static func paired(_ device: PluginBluetoothDevice) -> Self {
        Self(type: "paired", device: device, restored: nil, error: nil, state: nil)
    }
    static func unpaired(_ device: PluginBluetoothDevice) -> Self {
        Self(type: "unpaired", device: device, restored: nil, error: nil, state: nil)
    }
    static func stateChanged(_ state: PluginBluetoothState) -> Self {
        Self(type: "stateChanged", device: nil, restored: nil, error: nil, state: state.rawValue)
    }
}

/// What a hook that returns nothing answers with.
struct PluginBluetoothHookAnswer: Decodable {}

/// The radio for one declaring plugin (§10.1–10.2).
///
/// It owns one transport, scoped to the manifest's `services`; keeps a standing
/// connect to paired peripherals when the manifest asks for one; and turns
/// every link event into an `onBluetooth` invocation.
///
/// A `connected` invocation is the one that matters for correctness. It runs
/// under `BluetoothServiceLock` for the service, so the sibling Luna app's own
/// central cannot sweep the same window (§10.4), and inside a background lease,
/// so a hook woken by the radio finishes. A process that loses the lock stays
/// completely silent: the owner concludes the window.
public final class PluginBluetoothCenter: PluginBluetoothTransportDelegate {

    /// How long an `onBluetooth` invocation may take (§7.5).
    public static let hookTimeout: TimeInterval = 25

    public let pluginID: String

    private let declaration: PluginBluetoothDeclaration
    private let makers: any PluginTransportMaking
    private let pairing: (any PluginAccessoryPairing)?
    private let serviceLock: BluetoothServiceLock
    private let lease: (any PluginBackgroundLeasing)?
    private let pairedDevices: PluginPairedDeviceStore
    /// The `pairedDevice` field the manifest declares, so a pairing shows up in
    /// Settings without the plugin writing anything.
    private let pairedDeviceSettingKey: String?
    /// The manifest's settings schema, for the radio gate below.
    private let settingFields: [PluginSettingField]
    /// Set only by a test; production reads `PluginPlatformServices.invoker`.
    private let injectedInvoker: (any PluginHookInvoking)?

    private let queue = DispatchQueue(label: "com.hsanabria.luna.pluginBluetooth")
    private let lock = NSLock()
    /// Built on the first call that needs the radio, never at load.
    /// Instantiating a `CBCentralManager` is what raises the system Bluetooth
    /// prompt, and a plugin nobody set up must not raise one. State
    /// restoration still works: `startAll()` runs during launch, so a plugin
    /// that IS set up has its manager before iOS would restore it (TN3115).
    private var transport: (any PluginBluetoothTransporting)?
    private var session: PluginBluetoothSession?
    private var isStarted = false
    /// A foreground `connect(deviceId)` waiting for its link.
    private var connectWaiters: [String: (Result<PluginBluetoothSession, PluginTransportError>) -> Void] = [:]

    public init(
        pluginID: String,
        declaration: PluginBluetoothDeclaration,
        makers: any PluginTransportMaking,
        pairedDevices: PluginPairedDeviceStore = PluginPairedDeviceStore(),
        pairedDeviceSettingKey: String? = nil,
        settingFields: [PluginSettingField] = [],
        invoker: (any PluginHookInvoking)? = nil
    ) {
        self.pluginID = pluginID
        self.declaration = declaration
        self.makers = makers
        pairing = declaration.pairing == .accessorySetupKit
            ? makers.makePairing(pluginID: pluginID) : nil
        // The first declared service is the one the lock arbitrates: a plugin
        // talks to one device over one link, whatever else it advertises.
        serviceLock = makers.makeServiceLock(
            serviceUUID: declaration.services.first ?? pluginID)
        lease = makers.makeLease()
        self.pairedDevices = pairedDevices
        self.pairedDeviceSettingKey = pairedDeviceSettingKey
        self.settingFields = settingFields
        injectedInvoker = invoker
    }

    /// The radio, built on first use and kept.
    private func radio() -> any PluginBluetoothTransporting {
        lock.lock()
        if let transport {
            lock.unlock()
            return transport
        }
        let transport = makers.makeTransport(pluginID: pluginID)
        self.transport = transport
        lock.unlock()
        transport.transportDelegate = self
        return transport
    }

    /// The radio only if one was already built, so reading state raises no
    /// permission prompt of its own.
    private var existingRadio: (any PluginBluetoothTransporting)? {
        lock.lock()
        defer { lock.unlock() }
        return transport
    }

    private var invoker: (any PluginHookInvoking)? {
        injectedInvoker ?? PluginPlatformServices.invoker
    }

    /// The live session, for `luna.bluetooth.session()`. A hook the radio woke
    /// reads it, and so does an `export` call nested inside that hook.
    public var liveSession: PluginBluetoothSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    public var state: PluginBluetoothState { existingRadio?.state ?? .unknown }

    // MARK: - Lifecycle

    /// Whether the radio may open at all.
    ///
    /// Two settings answers stand it down, and both matter on a fresh install:
    /// a plugin whose REQUIRED settings are unfilled has nothing to talk to,
    /// and an `enabled` toggle the user turned off is the user saying so. A
    /// scan is what triggers the system Bluetooth permission prompt, so a
    /// plugin nobody set up must never open one.
    public var isPermittedToStart: Bool {
        guard let settings = PluginPlatformServices.settings else { return false }
        for field in settingFields where field.isRequired {
            guard let json = settings.valueJSON(pluginID: pluginID, key: field.key),
                  json != "null", json != "\"\"", json != "false"
            else { return false }
        }
        guard settingFields.contains(where: { $0.key == "enabled" && $0.type == .toggle })
        else { return true }
        return settings.valueJSON(pluginID: pluginID, key: "enabled") == "true"
    }

    /// Opens the standing connect and the scan. Called at launch and at every
    /// foreground: a restored central becomes ready long after launch, and a
    /// reader's wake window is short.
    public func start() {
        lock.lock()
        isStarted = true
        lock.unlock()
        let radio = radio()
        guard radio.state == .poweredOn else { return }
        if declaration.standingConnect {
            for device in pairedDevices.devices(pluginID: pluginID) {
                radio.connect(deviceID: device.id)
            }
        }
        radio.startScan(services: declaration.services)
    }


    // MARK: - Pairing

    public func knownDevices() -> [PluginBluetoothDevice] {
        let stored = pairedDevices.devices(pluginID: pluginID)
        let resolved = existingRadio?.knownDevices(ids: stored.map(\.id)) ?? []
        // The system's own name wins when it has one; the stored row is what
        // survives a reinstall of the plugin's context.
        return stored.map { device in
            guard let match = resolved.first(where: { $0.id == device.id }),
                  let name = match.name
            else { return device }
            return PluginBluetoothDevice(
                id: device.id, name: name, serviceUUIDs: device.serviceUUIDs)
        }
    }

    /// Runs the system pairing picker, tearing the transport down around it.
    ///
    /// `ASAccessorySession.showPicker` fails with ASErrorDomain 550 while the
    /// process holds any live `CBManager`, so the order is fixed: stand down
    /// prior authorizations, release the manager, show the picker, rebuild the
    /// manager on every exit path.
    public func pair(
        displayName: String,
        completion: @escaping (Result<PluginBluetoothDevice?, PluginTransportError>) -> Void
    ) {
        guard let pairing else {
            return completion(.failure(.unavailable("this plugin declares no pairing step")))
        }
        let radio = radio()
        pairing.removeSetUpAccessories { [self] in
            radio.releaseForAccessoryPicker { [self] in
                pairing.showPicker(
                    serviceUUIDs: declaration.services, displayName: displayName
                ) { [self] result in
                    radio.rebuildAfterAccessoryPicker()
                    guard case .success(let device) = result, let device else {
                        return completion(result)
                    }
                    pairedDevices.add(
                        device, pluginID: pluginID, settingKey: pairedDeviceSettingKey)
                    dispatch(.paired(device), holdingLock: false)
                    radio.connect(deviceID: device.id)
                    completion(.success(device))
                }
            }
        }
    }

    public func unpair(deviceID: String, completion: @escaping () -> Void) {
        let device = pairedDevices.devices(pluginID: pluginID).first { $0.id == deviceID }
        pairedDevices.remove(
            deviceID: deviceID, pluginID: pluginID, settingKey: pairedDeviceSettingKey)
        existingRadio?.cancelConnection(deviceID: deviceID)
        closeSession(reason: .disconnected)
        if let device { dispatch(.unpaired(device), holdingLock: false) }
        guard let pairing else { return completion() }
        pairing.removeAccessory(deviceID: deviceID) { completion() }
    }

    /// A foreground connect. It does NOT take the service lock: the caller is a
    /// user action in this app, not a sweep racing the sibling app.
    public func connect(
        deviceID: String, timeout: TimeInterval,
        completion: @escaping (Result<PluginBluetoothSession, PluginTransportError>) -> Void
    ) {
        if let live = liveSession, live.device.id == deviceID {
            return completion(.success(live))
        }
        let latch = OperationLatch()
        lock.lock()
        connectWaiters[deviceID] = { result in
            guard latch.take() else { return }
            completion(result)
        }
        lock.unlock()
        radio().connect(deviceID: deviceID)
        queue.asyncAfter(deadline: .now() + timeout) { [self] in
            lock.lock()
            let waiter = connectWaiters.removeValue(forKey: deviceID)
            lock.unlock()
            waiter?(.failure(.timedOut("the peripheral did not connect within \(Int(timeout))s")))
        }
    }

    // MARK: - PluginBluetoothTransportDelegate

    public func bluetoothTransportDidChangeState(_ state: PluginBluetoothState) {
        dispatch(.stateChanged(state), holdingLock: false)
        lock.lock()
        let started = isStarted
        lock.unlock()
        if state == .poweredOn, started { start() }
    }

    public func bluetoothTransportDidConnect(
        _ device: PluginBluetoothDevice, restored: Bool
    ) {
        let radio = radio()
        radio.stopScan()
        let session = PluginBluetoothSession(
            device: device, transport: radio, queue: queue)
        lock.lock()
        self.session = session
        let waiter = connectWaiters.removeValue(forKey: device.id)
        lock.unlock()
        // A peripheral that answered a connect is one worth keeping: the
        // standing connect completes the instant it advertises again.
        pairedDevices.add(device, pluginID: pluginID, settingKey: pairedDeviceSettingKey)
        if let waiter {
            // A foreground caller owns this link; it did not ask for a sweep.
            waiter(.success(session))
            return
        }
        dispatch(.connected(device, restored: restored), holdingLock: true)
    }

    public func bluetoothTransportDidDisconnect(
        _ device: PluginBluetoothDevice, error: String?
    ) {
        closeSession(reason: .disconnected)
        lock.lock()
        let waiter = connectWaiters.removeValue(forKey: device.id)
        let started = isStarted
        lock.unlock()
        waiter?(.failure(.disconnected))
        dispatch(.disconnected(device, error: error), holdingLock: false)
        if started { start() }
    }

    public func bluetoothTransport(
        didReceive base64: String, characteristicUUID: String, deviceID: String
    ) {
        liveSession?.deliver(notification: base64, characteristicUUID: characteristicUUID)
    }

    public func bluetoothTransportIsReadyToWrite(deviceID: String) {
        liveSession?.deliverReadyToWrite()
    }

    // MARK: - Dispatch

    private func closeSession(reason: PluginTransportError) {
        lock.lock()
        let live = session
        session = nil
        lock.unlock()
        live?.close(reason: reason)
    }

    /// Calls the plugin's `onBluetooth`.
    ///
    /// `holdingLock` is the `connected` case: the whole invocation — including
    /// the `luna.exports.deliverQueued()` a destination plugin awaits inside it
    /// — runs under the service lock, and a process that cannot take the lock
    /// invokes nothing at all.
    private func dispatch(_ event: PluginBluetoothEvent, holdingLock: Bool) {
        guard let invoker else { return }
        if holdingLock, !serviceLock.acquire() {
            PluginDiagnostics.shared.record(
                "another Luna app owns this rendezvous; staying silent", pluginID: pluginID)
            closeSession(reason: .unavailable("another process owns this link"))
            return
        }
        let token = lease?.beginLease(name: "plugin.\(pluginID).bluetooth")
        Task { [self] in
            _ = await invoker.invoke(
                .onBluetooth, pluginID: pluginID, argument: event,
                timeout: Self.hookTimeout, decode: PluginBluetoothHookAnswer?.self)
            if holdingLock {
                closeSession(reason: .unavailable("the hook finished"))
                serviceLock.release()
            }
            if let token { lease?.endLease(token) }
        }
    }
}

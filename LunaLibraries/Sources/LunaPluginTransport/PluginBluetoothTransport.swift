//
//  PluginBluetoothTransport.swift
//  LunaPluginTransport
//

import Foundation

/// One peripheral as the transport tier and `luna.bluetooth` see it
/// (`claudedocs/plans/plugin-platform.md` §10.1's `BluetoothDevice`).
public struct PluginBluetoothDevice: Equatable, Sendable, Codable {
    public let id: String
    public let name: String?
    public let serviceUUIDs: [String]

    public init(id: String, name: String?, serviceUUIDs: [String]) {
        self.id = id
        self.name = name
        self.serviceUUIDs = serviceUUIDs
    }

    /// The shape `luna.bluetooth` hands to JavaScript.
    var jsObject: [String: Any] {
        var object: [String: Any] = ["id": id, "serviceUUIDs": serviceUUIDs]
        if let name { object["name"] = name }
        return object
    }
}

/// The radio's own state, as `luna.bluetooth.state()` reports it.
public enum PluginBluetoothState: String, Sendable, Codable {
    case poweredOn, poweredOff, unauthorized, unsupported, unknown
}

/// Why a transport call could not be served.
public struct PluginTransportError: Error, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    static let disconnected = PluginTransportError(
        code: "disconnected", message: "the peripheral disconnected")
    static func unavailable(_ message: String) -> PluginTransportError {
        PluginTransportError(code: "bluetooth-unavailable", message: message)
    }
    static func timedOut(_ message: String) -> PluginTransportError {
        PluginTransportError(code: "timed-out", message: message)
    }
}

/// What the transport tells its owner. Weak, like every component-boundary
/// delegate: the center owns the transport.
public protocol PluginBluetoothTransportDelegate: AnyObject {
    func bluetoothTransportDidChangeState(_ state: PluginBluetoothState)
    func bluetoothTransportDidConnect(_ device: PluginBluetoothDevice, restored: Bool)
    func bluetoothTransportDidDisconnect(_ device: PluginBluetoothDevice, error: String?)
    /// A notification the peripheral published on a subscribed characteristic.
    func bluetoothTransport(
        didReceive base64: String, characteristicUUID: String, deviceID: String)
    /// The controller has room for another write-without-response.
    func bluetoothTransportIsReadyToWrite(deviceID: String)
}

/// The CoreBluetooth surface `PluginBluetoothCenter` uses, as a protocol so a
/// test drives the center without a radio.
///
/// Every call is asynchronous through a completion because CoreBluetooth is:
/// the adapter hops to its own queue and answers from a delegate callback.
public protocol PluginBluetoothTransporting: AnyObject {
    var state: PluginBluetoothState { get }
    var transportDelegate: PluginBluetoothTransportDelegate? { get set }

    /// Scans for peripherals advertising any of `services`. A peripheral
    /// another process already holds has stopped advertising, so the adapter
    /// asks the system for connected ones first.
    func startScan(services: [String])
    func stopScan()
    /// Opens a connect that CoreBluetooth keeps pending until the peripheral
    /// advertises. `deviceID` may name a peripheral this process has never
    /// seen, in which case nothing happens.
    func connect(deviceID: String)
    func cancelConnection(deviceID: String)
    /// Peripherals the system can resolve from stored identifiers.
    func knownDevices(ids: [String]) -> [PluginBluetoothDevice]

    func discover(
        serviceUUID: String, deviceID: String,
        completion: @escaping (Result<[String], PluginTransportError>) -> Void)
    func read(
        characteristicUUID: String, deviceID: String,
        completion: @escaping (Result<String, PluginTransportError>) -> Void)
    /// `withResponse: false` is link-layer reliable but not an application
    /// acknowledgement; the center paces it against `canWriteWithoutResponse`.
    func write(
        base64: String, characteristicUUID: String, deviceID: String, withResponse: Bool,
        completion: @escaping (Result<Void, PluginTransportError>) -> Void)
    func subscribe(
        characteristicUUID: String, deviceID: String,
        completion: @escaping (Result<Void, PluginTransportError>) -> Void)
    /// `maximumWriteValueLength(for: .withoutResponse)`.
    func maximumWriteLength(deviceID: String) -> Int
    func canWriteWithoutResponse(deviceID: String) -> Bool

    /// Tears the manager down for the accessory picker's lifetime, then
    /// rebuilds it. `ASAccessorySession.showPicker` fails with ASErrorDomain
    /// 550 while the process holds any live `CBManager`.
    func releaseForAccessoryPicker(completion: @escaping () -> Void)
    func rebuildAfterAccessoryPicker()
}

/// The system pairing step, as a protocol so the pair flow is testable without
/// AccessorySetupKit's picker.
public protocol PluginAccessoryPairing: AnyObject {
    /// Shows the system picker scoped to `serviceUUIDs`. Answers nil when the
    /// user dismissed it without choosing.
    func showPicker(
        serviceUUIDs: [String], displayName: String,
        completion: @escaping (Result<PluginBluetoothDevice?, PluginTransportError>) -> Void)
    /// Removes every accessory this app set up, so a re-pair starts clean: the
    /// picker never lists an accessory it considers already set up.
    func removeSetUpAccessories(completion: @escaping () -> Void)
    func removeAccessory(deviceID: String, completion: @escaping () -> Void)
}

/// A background execution lease, so a hook woken by the radio finishes.
public protocol PluginBackgroundLeasing: AnyObject {
    /// Answers a token to end the lease with, or nil where none is available.
    func beginLease(name: String) -> Int?
    func endLease(_ token: Int)
}

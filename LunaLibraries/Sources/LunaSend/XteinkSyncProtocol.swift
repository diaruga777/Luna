//
//  XteinkSyncProtocol.swift
//  Luna
//

import CoreBluetooth
import CryptoKit
import Foundation
import LunaStorage

public extension Notification.Name {
    /// Posted only after the X3 GATT service and required characteristics are
    /// ready. Reader wiring uses this to re-run the queued-send sweep.
    static let xteinkRendezvousReady = Notification.Name("xteinkRendezvousReady")
}

/// Wire constants shared with the Xteink X3 CrossPoint `luna_sync` feature.
/// Luna is the central and the reader is the peripheral. Keep v1 UUIDs stable:
/// an installed reader must remain usable after Luna updates.
public enum XteinkSyncProtocol {
    public static let version = 1
    public static let service = CBUUID(string: "6F9F0A00-9B1D-4D1F-9F53-5B6B8B3D0F10")
    public static let control = CBUUID(string: "6F9F0A01-9B1D-4D1F-9F53-5B6B8B3D0F10")
    public static let dataIn = CBUUID(string: "6F9F0A02-9B1D-4D1F-9F53-5B6B8B3D0F10")
    public static let status = CBUUID(string: "6F9F0A03-9B1D-4D1F-9F53-5B6B8B3D0F10")
    public static let dataOut = CBUUID(string: "6F9F0A04-9B1D-4D1F-9F53-5B6B8B3D0F10")
    /// The BLE payload limit. Larger EPUBs request the reader's Wi-Fi path.
    /// Kept here until the shared transfer-policy type lands.
    public static let maximumBLEPayloadBytes = 200 * 1024

    static func controlData(_ operation: String, values: [String: Any] = [:]) throws -> Data {
        var payload: [String: Any] = values
        payload["op"] = operation
        payload["version"] = version
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    static func frame(sequence: UInt32, payload: Data) -> Data {
        var littleEndian = sequence.littleEndian
        var frame = Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size)
        frame.append(payload)
        return frame
    }
}

/// Reader-provided route for an oversized EPUB. The reader tries its remembered
/// station briefly, then supplies this secured AP without a long network sweep.
public struct XteinkWiFiOffer: Equatable, Sendable {
    public enum Mode: String, Equatable, Sendable { case sta, ap }
    public let mode: Mode
    public let ssid: String
    public let passphrase: String
    public let host: String

    public init(mode: Mode, ssid: String = "", passphrase: String = "", host: String) {
        self.mode = mode; self.ssid = ssid
        self.passphrase = passphrase
        self.host = host
    }
}

public struct XteinkSyncProgress: Equatable, Sendable {
    public let completedBytes: Int
    public let totalBytes: Int
    public init(completedBytes: Int, totalBytes: Int) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }
}

public enum XteinkSyncError: Error, Equatable {
    case unavailable
    case cancelled
    case protocolError(String)
    case pairingRequired
    case transferFailed(String)
}

/// Narrow seam used by the sender and unit tests. A real central only reports
/// `available` while it has a live rendezvous connection; this is deliberate so
/// a normal sleeping X3 does not turn into a retry-consuming failure.
public protocol XteinkBLETransporting: AnyObject {
    var isRendezvousActive: Bool { get }
    func send(
        _ epub: Data, fileName: String, title: String,
        progress: @escaping @Sendable (XteinkSyncProgress) -> Void
    ) async throws
    func requestWiFi() async throws -> XteinkWiFiOffer
    func delete(remotePath: String) async throws
}

/// Secure pairing material deliberately lives in the shared access-group
/// Keychain, not UserDefaults. The device id is supplied by the reader's hello.
public protocol XteinkPairingStoring: Sendable {
    func credential(for deviceID: String) -> String?
    func save(_ credential: String, for deviceID: String)
    func removeCredential(for deviceID: String)
}

public struct XteinkKeychainPairingStore: XteinkPairingStoring {
    private let service = "com.hsanabria.luna.xteink-pairing"
    public init() {}
    public func credential(for deviceID: String) -> String? {
        CredentialKeychain.read(service: service, account: deviceID)
    }
    public func save(_ credential: String, for deviceID: String) {
        CredentialKeychain.write(credential, service: service, account: deviceID)
    }
    public func removeCredential(for deviceID: String) {
        CredentialKeychain.delete(service: service, account: deviceID)
    }
}

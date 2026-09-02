//
//  BluetoothServiceLock.swift
//  LunaStorage
//

import Foundation
import LunaAppConfig

/// Cross-process mutual exclusion for one GATT service's link.
///
/// iOS shares one physical BLE link between every process that connects to a
/// peripheral, and Luna reaches a given service from more than one app: the
/// central app's Xteink plugin and the Reader's Swift `XteinkBLECentral` both
/// see the same rendezvous become ready. Two sweeps over one session interleave
/// control operations and data frames, which the peripheral rejects and the
/// transfer dies. Only the process that wins this `flock` talks to the service;
/// the loser stays completely silent, because the owner concludes the window.
///
/// The lock file path is a pure function of the service UUID, so the plugin
/// bridge (`LunaPluginTransport`) and the Reader's Swift path derive the same
/// file for the same service without sharing a constant.
///
/// `flock` is per open-file-description, so the lock also excludes a second
/// acquire inside one process, and the kernel releases it if the holder dies.
public final class BluetoothServiceLock: @unchecked Sendable {

    /// The lock file for `serviceUUID`, or nil where no shared container
    /// exists. Case and surrounding braces are normalized away, so a
    /// lower-case UUID and CoreBluetooth's upper-case spelling of it lock each
    /// other out.
    public static func lockFileURL(serviceUUID: String) -> URL? {
        AppConfig.sharedContainerURL()?
            .appendingPathComponent("bluetooth-service-\(normalized(serviceUUID)).lock")
    }

    static func normalized(_ serviceUUID: String) -> String {
        let permitted = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return serviceUUID.uppercased().unicodeScalars
            .filter { permitted.contains($0) }
            .map(String.init).joined()
    }

    private static let registryLock = NSLock()
    private static var registry: [String: BluetoothServiceLock] = [:]

    /// The one lock this process holds for `serviceUUID`. `flock` excludes a
    /// second acquire on a second descriptor anyway; one instance keeps the
    /// in-process `held` flag meaningful too.
    public static func shared(serviceUUID: String) -> BluetoothServiceLock {
        let key = normalized(serviceUUID)
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[key] { return existing }
        let lock = BluetoothServiceLock(serviceUUID: serviceUUID)
        registry[key] = lock
        return lock
    }

    private let stateLock = NSLock()
    private var descriptor: Int32 = -1
    private var held = false
    private let fileURL: URL?

    public init(serviceUUID: String) {
        fileURL = Self.lockFileURL(serviceUUID: serviceUUID)
    }

    /// Locks a path directly, for a test that must not reach the App Group.
    public init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    /// The file this instance locks, for the parity check between the Swift
    /// path and the plugin bridge.
    public var lockFileURL: URL? { fileURL }

    /// Attempts the lock without blocking. When no shared container exists
    /// (nothing to arbitrate through), it degrades to a per-process flag so the
    /// work still runs exactly once.
    public func acquire() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !held else { return false }
        if let path = fileURL?.path {
            let fd = open(path, O_CREAT | O_RDWR, 0o644)
            if fd >= 0 {
                guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                    close(fd)
                    return false
                }
                descriptor = fd
            }
        }
        held = true
        return true
    }

    public func release() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
        held = false
    }
}

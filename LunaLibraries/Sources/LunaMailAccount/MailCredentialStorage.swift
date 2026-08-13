//
//  MailCredentialStorage.swift
//  LunaMailAccount
//

import Foundation
import LunaStorage

/// Where `EmailAccountStore` persists the account **secret** (the metadata lives
/// in `UserDefaults` directly). Exists so tests can swap the Keychain for an
/// in-memory stand-in without touching `EmailAccountStore`'s own logic.
public protocol MailCredentialStorage: Sendable {
    func read(service: String, account: String) -> String?
    func write(_ value: String?, service: String, account: String)
    func delete(service: String, account: String)
}

/// Production default: wraps `LunaStorage.CredentialKeychain` byte-for-byte —
/// same calls `EmailAccountStore` made directly before this seam existed.
public struct KeychainCredentialStorage: MailCredentialStorage {
    public init() {}

    public func read(service: String, account: String) -> String? {
        CredentialKeychain.read(service: service, account: account)
    }

    public func write(_ value: String?, service: String, account: String) {
        CredentialKeychain.write(value, service: service, account: account)
    }

    public func delete(service: String, account: String) {
        CredentialKeychain.delete(service: service, account: account)
    }
}

/// A scratch, process-local credential store. Nothing written here ever reaches
/// the real Keychain — used by tests that exercise sign-in without leaving a real
/// credential behind.
public final class InMemoryCredentialStorage: MailCredentialStorage, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    private func key(service: String, account: String) -> String { "\(service)|\(account)" }

    public func read(service: String, account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key(service: service, account: account)]
    }

    public func write(_ value: String?, service: String, account: String) {
        lock.lock()
        defer { lock.unlock() }
        let key = key(service: service, account: account)
        if let value, !value.isEmpty {
            storage[key] = value
        } else {
            storage.removeValue(forKey: key)
        }
    }

    public func delete(service: String, account: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key(service: service, account: account))
    }
}

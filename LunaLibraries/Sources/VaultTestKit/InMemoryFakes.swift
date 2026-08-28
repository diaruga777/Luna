import Foundation
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultModels
import LunaVaultStorage

public final class InMemoryVaultKeyStore: VaultKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [VaultKeyDescriptor: Data]

    public init(values: [VaultKeyDescriptor: Data] = [:]) {
        self.values = values
    }

    public func data(for descriptor: VaultKeyDescriptor) throws -> Data? {
        lock.withLock { values[descriptor] }
    }

    public func setData(_ data: Data, for descriptor: VaultKeyDescriptor) throws {
        lock.withLock { values[descriptor] = data }
    }

    public func removeData(for descriptor: VaultKeyDescriptor) throws {
        _ = lock.withLock { values.removeValue(forKey: descriptor) }
    }

    /// Atomically replaces a key and returns its previous value, mirroring the
    /// operation the production root-key rotation path will require.
    @discardableResult
    public func rotateData(_ data: Data, for descriptor: VaultKeyDescriptor) -> Data? {
        lock.withLock {
            let previous = values[descriptor]
            values[descriptor] = data
            return previous
        }
    }

    /// Simulates replacing the phone: synchronizable Keychain records survive,
    /// device-local records do not.
    public func simulateDeviceLoss() {
        lock.withLock {
            values = values.filter { descriptor, _ in descriptor.synchronizable }
        }
    }

    public func removeAll() {
        lock.withLock { values.removeAll() }
    }

    public var descriptors: [VaultKeyDescriptor] {
        lock.withLock {
            values.keys.sorted {
                ($0.service, $0.account, $0.accessGroup) < ($1.service, $1.account, $1.accessGroup)
            }
        }
    }
}

public final class InMemoryVaultObjectStore: VaultObjectStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [VaultObjectID: Data]

    public init(values: [VaultObjectID: Data] = [:]) {
        self.values = values
    }

    public func data(for id: VaultObjectID) throws -> Data? {
        lock.withLock { values[id] }
    }

    public func setData(_ data: Data, for id: VaultObjectID) throws {
        lock.withLock { values[id] = data }
    }

    public func removeData(for id: VaultObjectID) throws {
        _ = lock.withLock { values.removeValue(forKey: id) }
    }
}

public actor InMemoryVaultBackend: VaultBackendTransport {
    private var values: [VaultObjectID: Data]

    public init(values: [VaultObjectID: Data] = [:]) {
        self.values = values
    }

    public func putCiphertext(_ ciphertext: Data, for id: VaultObjectID) async throws {
        values[id] = ciphertext
    }

    public func ciphertext(for id: VaultObjectID) async throws -> Data? {
        values[id]
    }

    public func removeCiphertext(for id: VaultObjectID) async throws {
        values.removeValue(forKey: id)
    }

    public func allObjectIDs() -> [VaultObjectID] {
        values.keys.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
    }
}

import Foundation
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultModels
import LunaVaultStorage

public final class InMemoryVaultKeyStore: VaultKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data]

    public init(values: [String: Data] = [:]) {
        self.values = values
    }

    public func data(forKey key: String) throws -> Data? {
        lock.withLock { values[key] }
    }

    public func setData(_ data: Data, forKey key: String) throws {
        lock.withLock { values[key] = data }
    }

    public func removeData(forKey key: String) throws {
        _ = lock.withLock { values.removeValue(forKey: key) }
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

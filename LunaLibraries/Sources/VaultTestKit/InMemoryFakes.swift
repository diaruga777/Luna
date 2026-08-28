import Foundation
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultModels
import LunaVaultStorage

public final class InMemoryVaultUbiquitousCoordinator: VaultUbiquitousFileCoordinating, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data]
    private var downloaded: Set<String>
    private var ubiquitous: Set<String>
    public let rootURL: URL?
    public let availability: VaultBackendAvailability
    public var evictionRemainsPending = false

    public init(rootURL: URL? = URL(fileURLWithPath: "/in-memory-ubiquity", isDirectory: true),
                values: [String: Data] = [:], downloaded: Bool = true, ubiquitous: Bool = true) {
        self.rootURL = rootURL
        self.availability = rootURL == nil ? .unavailable : .available
        self.values = values
        self.downloaded = Set(downloaded ? Array(values.keys) : [])
        self.ubiquitous = Set(ubiquitous ? Array(values.keys) : [])
    }

    public func state(for relativePath: String) throws -> VaultUbiquitousFileState {
        lock.withLock {
            VaultUbiquitousFileState(
                exists: values[relativePath] != nil,
                isUbiquitous: ubiquitous.contains(relativePath),
                isDownloaded: downloaded.contains(relativePath),
                isDownloading: false,
                isUploaded: ubiquitous.contains(relativePath))
        }
    }

    public func write(_ data: Data, at relativePath: String) throws {
        lock.withLock {
            values[relativePath] = data
            ubiquitous.insert(relativePath)
            downloaded.insert(relativePath)
        }
    }

    public func read(at relativePath: String) throws -> Data? {
        lock.withLock { values[relativePath] }
    }

    public func remove(at relativePath: String) throws {
        lock.withLock {
            values.removeValue(forKey: relativePath)
            downloaded.remove(relativePath)
            ubiquitous.remove(relativePath)
        }
    }

    public func startDownloading(at relativePath: String) throws {
        _ = lock.withLock { downloaded.insert(relativePath) }
    }

    public func requestEviction(at relativePath: String) throws -> VaultEvictionOutcome {
        lock.withLock {
            guard values[relativePath] != nil, ubiquitous.contains(relativePath) else { return .notEvictable }
            if !evictionRemainsPending { downloaded.remove(relativePath); return .evicted }
            return .pending
        }
    }

    public func bytes(at relativePath: String) -> Data? { lock.withLock { values[relativePath] } }
}

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

    public nonisolated let capabilities = VaultBackendCapabilities(
        location: .mac,
        availability: .available,
        supportsAtomicWrites: true,
        supportsRangeReads: true,
        supportsEviction: false,
        requiresClientSideEncryption: true)

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

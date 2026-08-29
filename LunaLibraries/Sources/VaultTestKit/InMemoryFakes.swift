import Foundation
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultModels
import LunaVaultStorage
import LunaVaultSync

public final class InMemoryVaultUbiquitousCoordinator: VaultUbiquitousFileCoordinating, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data]
    private var downloaded: Set<String>
    private var ubiquitous: Set<String>
    public let rootURL: URL?
    public let availability: VaultBackendAvailability
    public var evictionRemainsPending = false
    public var uploadRemainsPending = false
    public var uploadFails = false
    public var downloadedIsCurrent = true
    public var hasUnresolvedConflicts = false
    public var evictionError: VaultBackendError?

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
                isCurrent: downloaded.contains(relativePath) && downloadedIsCurrent,
                isDownloading: false,
                isUploaded: ubiquitous.contains(relativePath) && !uploadRemainsPending,
                isUploading: uploadRemainsPending,
                uploadFailed: uploadFails,
                hasUnresolvedConflicts: hasUnresolvedConflicts)
        }
    }

    public func writeIfAbsentOrIdentical(_ data: Data, at relativePath: String) throws {
        try lock.withLock {
            if let existing = values[relativePath], existing != data {
                throw VaultBackendError.conflict
            }
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
        lock.withLock { downloaded.insert(relativePath); downloadedIsCurrent = true }
    }

    public func requestEviction(at relativePath: String) throws -> VaultEvictionOutcome {
        try lock.withLock {
            if let evictionError { throw evictionError }
            guard values[relativePath] != nil, ubiquitous.contains(relativePath) else { return .notEvictable }
            if !evictionRemainsPending { downloaded.remove(relativePath); return .evicted }
            return .pending
        }
    }

    public func bytes(at relativePath: String) -> Data? { lock.withLock { values[relativePath] } }
}

public actor InMemoryVaultSyncPayloadStore: VaultSyncPayloadSource {
    private var staged: [VaultRemoteObjectIdentity: VaultAuthenticatedCiphertext] = [:]
    private var downloaded: [VaultRemoteObjectIdentity: VaultAuthenticatedCiphertext] = [:]

    public init() {}
    public func stageUpload(_ payload: VaultAuthenticatedCiphertext) async throws { staged[payload.identity] = payload }
    public func uploadPayload(for identity: VaultRemoteObjectIdentity) async throws -> VaultAuthenticatedCiphertext? { staged[identity] }
    public func installDownloadedPayload(_ payload: VaultAuthenticatedCiphertext) async throws { downloaded[payload.identity] = payload }
    public func removeStagedPayload(for identity: VaultRemoteObjectIdentity) async throws { staged.removeValue(forKey: identity) }
    public func downloadedPayload(for identity: VaultRemoteObjectIdentity) -> VaultAuthenticatedCiphertext? { downloaded[identity] }
    public func stagedPayload(for identity: VaultRemoteObjectIdentity) -> VaultAuthenticatedCiphertext? { staged[identity] }
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
    private var values: [VaultRemoteObjectIdentity: VaultAuthenticatedCiphertext]
    private var states: [VaultRemoteObjectIdentity: VaultRemoteObjectState]
    private var injectedFailures: [VaultBackendError]

    public nonisolated let identity: VaultBackendIdentity

    public nonisolated let capabilities = VaultBackendCapabilities(
        location: .mac,
        availability: .available,
        supportsAtomicWrites: true,
        supportsRangeReads: true,
        supportsEviction: false,
        requiresClientSideEncryption: true)

    public init(identity: VaultBackendIdentity = VaultBackendIdentity(
                    location: .mac, containerIdentifier: "memory", vaultID: "default"),
                values: [VaultRemoteObjectIdentity: VaultAuthenticatedCiphertext] = [:],
                states: [VaultRemoteObjectIdentity: VaultRemoteObjectState] = [:],
                failures: [VaultBackendError] = []) {
        self.identity = identity
        self.values = values
        self.states = states
        injectedFailures = failures
    }

    public func put(_ payload: VaultAuthenticatedCiphertext,
                    expectedRevision: UUID?) async throws -> VaultBackendWriteOutcome {
        try failIfInjected()
        if let expectedRevision, expectedRevision != payload.identity.revision {
            throw VaultBackendError.staleVersion
        }
        values[payload.identity] = payload
        let state = states[payload.identity] ?? .current
        states[payload.identity] = state
        return state == .current ? .current : .pending
    }

    public func payload(for identity: VaultRemoteObjectIdentity) async throws -> VaultAuthenticatedCiphertext? {
        try failIfInjected()
        return values[identity]
    }

    public func remove(_ identity: VaultRemoteObjectIdentity,
                       expectedRevision: UUID?) async throws {
        try failIfInjected()
        if let expectedRevision, expectedRevision != identity.revision {
            throw VaultBackendError.staleVersion
        }
        values.removeValue(forKey: identity)
        states[identity] = .missing
    }

    public func state(for identity: VaultRemoteObjectIdentity) async throws -> VaultRemoteObjectState {
        try failIfInjected()
        return states[identity] ?? (values[identity] == nil ? .missing : .current)
    }

    public func setState(_ state: VaultRemoteObjectState, for identity: VaultRemoteObjectIdentity) {
        states[identity] = state
    }

    public func allObjectIDs() -> [VaultObjectID] {
        values.keys.map(\.objectID).sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
    }

    private func failIfInjected() throws {
        if !injectedFailures.isEmpty { throw injectedFailures.removeFirst() }
    }
}

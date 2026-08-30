import Foundation

public enum LunaVaultModelsModule {
    public static let identifier = "LunaVaultModels"
}

/// Opaque identity shared by Vault tiers. It intentionally carries no path,
/// filename, provider key or other remotely observable metadata.
public struct VaultObjectID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct VaultRevision: Codable, Hashable, Sendable {
    public let objectID: VaultObjectID
    public let revision: UUID
    public let logicalTime: Int64
    public let deviceID: String

    public init(objectID: VaultObjectID, revision: UUID = UUID(), logicalTime: Int64, deviceID: String) {
        self.objectID = objectID; self.revision = revision; self.logicalTime = logicalTime; self.deviceID = deviceID
    }
}

public struct VaultObjectRecord: Codable, Hashable, Sendable {
    public let id: VaultObjectID
    public let revision: UUID
    public let logicalTime: Int64
    public let size: Int64
    public let contentType: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let accessedAt: Date
    public let isTombstone: Bool
    public let deviceID: String

    public init(id: VaultObjectID, revision: UUID, logicalTime: Int64, size: Int64,
                contentType: String? = nil, createdAt: Date, updatedAt: Date,
                accessedAt: Date, isTombstone: Bool = false, deviceID: String = "") {
        self.id = id; self.revision = revision; self.logicalTime = logicalTime; self.size = size
        self.contentType = contentType; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.accessedAt = accessedAt; self.isTombstone = isTombstone; self.deviceID = deviceID
    }
}

public struct VaultTombstone: Codable, Hashable, Sendable {
    public let id: VaultObjectID
    public let revision: UUID
    public let logicalTime: Int64
    public let deletedAt: Date
    public let deviceID: String
    public init(id: VaultObjectID, revision: UUID, logicalTime: Int64, deletedAt: Date, deviceID: String = "") {
        self.id = id; self.revision = revision; self.logicalTime = logicalTime; self.deletedAt = deletedAt; self.deviceID = deviceID
    }
}

public struct VaultHLC: Codable, Hashable, Sendable, Comparable {
    public let physicalMilliseconds: Int64
    public let counter: Int64
    public init(physicalMilliseconds: Int64, counter: Int64 = 0) {
        self.physicalMilliseconds = physicalMilliseconds; self.counter = counter
    }
    public static func < (lhs: VaultHLC, rhs: VaultHLC) -> Bool {
        lhs.physicalMilliseconds == rhs.physicalMilliseconds ? lhs.counter < rhs.counter : lhs.physicalMilliseconds < rhs.physicalMilliseconds
    }
    public var encoded: Int64 { physicalMilliseconds &* 1_000_000 &+ counter }
}

public enum VaultJobKind: String, Codable, Sendable { case importFile, index, upload, download, delete }
public enum VaultJobState: String, Codable, Sendable { case queued, running, retrying, succeeded, failed, cancelled }
public struct VaultJob: Codable, Hashable, Sendable {
    public let id: UUID; public let kind: VaultJobKind; public let objectID: VaultObjectID?
    public var state: VaultJobState; public var attempts: Int; public var nextAttemptAt: Date?
    public var lastError: String?; public let createdAt: Date; public var updatedAt: Date
    public let idempotencyKey: String
    public let revision: UUID?
    public let backendKey: String?
    public let payloadGeneration: String?
    public let remoteObjectKind: String?
    public let expectedRemoteRevision: UUID?
    public var leaseOwner: String?
    public var leaseToken: UUID?
    public var leaseExpiresAt: Date?
    public init(id: UUID = UUID(), kind: VaultJobKind, objectID: VaultObjectID? = nil, state: VaultJobState = .queued,
                attempts: Int = 0, nextAttemptAt: Date? = nil, lastError: String? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date(), idempotencyKey: String? = nil,
                revision: UUID? = nil, backendKey: String? = nil,
                payloadGeneration: String? = nil, remoteObjectKind: String? = nil,
                expectedRemoteRevision: UUID? = nil, leaseOwner: String? = nil,
                leaseToken: UUID? = nil, leaseExpiresAt: Date? = nil) {
        self.id=id; self.kind=kind; self.objectID=objectID; self.state=state; self.attempts=attempts
        self.nextAttemptAt=nextAttemptAt; self.lastError=lastError; self.createdAt=createdAt; self.updatedAt=updatedAt
        self.idempotencyKey=idempotencyKey ?? id.uuidString; self.leaseOwner=leaseOwner; self.leaseExpiresAt=leaseExpiresAt
        self.revision=revision;self.backendKey=backendKey;self.payloadGeneration=payloadGeneration
        self.remoteObjectKind=remoteObjectKind;self.expectedRemoteRevision=expectedRemoteRevision;self.leaseToken=leaseToken
    }
}

public struct VaultCacheEntry: Codable, Hashable, Sendable {
    public let objectID: VaultObjectID; public let byteCount: Int64; public let fullContent: Bool
    public var lastAccessedAt: Date; public let createdAt: Date; public var pinned: Bool
    /// A caller may retain a cache entry for a preview or another operation
    /// even when it is not user-pinned. Eviction must honour this independent
    /// policy bit; older serialized entries default to `true`.
    public var supportsEviction: Bool
    public init(objectID: VaultObjectID, byteCount: Int64, fullContent: Bool, lastAccessedAt: Date,
                createdAt: Date, pinned: Bool = false, supportsEviction: Bool = true) {
        self.objectID=objectID; self.byteCount=byteCount; self.fullContent=fullContent
        self.lastAccessedAt=lastAccessedAt; self.createdAt=createdAt; self.pinned=pinned
        self.supportsEviction=supportsEviction
    }

    private enum CodingKeys: String, CodingKey { case objectID, byteCount, fullContent, lastAccessedAt, createdAt, pinned, supportsEviction }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        objectID = try c.decode(VaultObjectID.self, forKey: .objectID)
        byteCount = try c.decode(Int64.self, forKey: .byteCount)
        fullContent = try c.decode(Bool.self, forKey: .fullContent)
        lastAccessedAt = try c.decode(Date.self, forKey: .lastAccessedAt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        supportsEviction = try c.decodeIfPresent(Bool.self, forKey: .supportsEviction) ?? true
    }
}

/// The only storage locations supported by the first Vault release. Provider
/// names deliberately do not appear in the public model: Vault is a gateway
/// to user-owned device, iCloud, or Mac storage, not a cloud-provider catalog.
public enum VaultStorageLocation: String, Codable, CaseIterable, Sendable {
    case device
    case iCloud
    case mac
}

/// iCloud can retain the canonical copy while the local working copy is
/// evicted. `keepLocalCopy` is a policy, not a second backend.
public struct VaultStoragePolicy: Codable, Equatable, Sendable {
    public let location: VaultStorageLocation
    public let keepLocalCopy: Bool

    public init(location: VaultStorageLocation, keepLocalCopy: Bool = true) {
        self.location = location
        self.keepLocalCopy = location == .iCloud ? keepLocalCopy : true
    }
}

public protocol VaultClock: Sendable {
    func now() -> Date
}

public protocol VaultUUIDGenerating: Sendable {
    func next() -> UUID
}

public protocol VaultRandomBytesGenerating: Sendable {
    func bytes(count: Int) throws -> Data
}

/// Storage boundary for the on-device index artifact.  The payload is already
/// serialized (and, before it leaves the device, encrypted by the crypto tier),
/// so this model layer never needs to know the extraction schema.
public protocol VaultExtractionArtifactStoring: Sendable {
    func extractionArtifact(objectID: VaultObjectID, revision: UUID, modelVersion: String) throws -> Data?
    func putExtractionArtifact(_ data: Data, objectID: VaultObjectID, revision: UUID, modelVersion: String) throws
    func removeExtractionArtifacts(for objectID: VaultObjectID) throws
}

/// Optional durable job seam used by the extraction coordinator.  The storage
/// tier owns the concrete SQLite implementation; tests can provide a tiny
/// deterministic fake without importing SQLite or any network code.
public protocol VaultExtractionJobScheduling: Sendable {
    func enqueueExtractionJob(objectID: VaultObjectID, revision: UUID, modelVersion: String) throws
}

public struct VaultExtractionJobLease: Equatable, Sendable {
    public let jobID: UUID
    public let owner: String
    /// Stage 4 uses an unguessable token in addition to the owner.  The
    /// optional value keeps the Stage 3 protocol/fake initializer source
    /// compatible while concrete storage always returns a token.
    public let leaseToken: UUID?
    public init(jobID: UUID, owner: String, leaseToken: UUID? = nil) {
        self.jobID = jobID; self.owner = owner; self.leaseToken = leaseToken
    }
}

/// Durable lifecycle for one extraction attempt. Implementations must claim a
/// lease atomically and reject completion by a stale or different owner.
public protocol VaultExtractionJobCoordinating: Sendable {
    func beginExtractionJob(objectID: VaultObjectID, revision: UUID, modelVersion: String,
                            owner: String, now: Date, leaseDuration: TimeInterval) throws -> VaultExtractionJobLease
    func transitionExtractionJob(_ lease: VaultExtractionJobLease, to state: VaultJobState,
                                 error: String?, retryAt: Date?, now: Date) throws
}

public enum VaultScaffoldError: Error, Equatable, Sendable {
    case invalidByteCount(Int)
    case missingValue(String)
    case noEgress(URL)
}

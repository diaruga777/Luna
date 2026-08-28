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
    public var leaseOwner: String?
    public var leaseExpiresAt: Date?
    public init(id: UUID = UUID(), kind: VaultJobKind, objectID: VaultObjectID? = nil, state: VaultJobState = .queued,
                attempts: Int = 0, nextAttemptAt: Date? = nil, lastError: String? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date(), idempotencyKey: String? = nil,
                leaseOwner: String? = nil, leaseExpiresAt: Date? = nil) {
        self.id=id; self.kind=kind; self.objectID=objectID; self.state=state; self.attempts=attempts
        self.nextAttemptAt=nextAttemptAt; self.lastError=lastError; self.createdAt=createdAt; self.updatedAt=updatedAt
        self.idempotencyKey=idempotencyKey ?? id.uuidString; self.leaseOwner=leaseOwner; self.leaseExpiresAt=leaseExpiresAt
    }
}

public struct VaultCacheEntry: Codable, Hashable, Sendable {
    public let objectID: VaultObjectID; public let byteCount: Int64; public let fullContent: Bool
    public var lastAccessedAt: Date; public let createdAt: Date; public var pinned: Bool
    public init(objectID: VaultObjectID, byteCount: Int64, fullContent: Bool, lastAccessedAt: Date,
                createdAt: Date, pinned: Bool = false) {
        self.objectID=objectID; self.byteCount=byteCount; self.fullContent=fullContent
        self.lastAccessedAt=lastAccessedAt; self.createdAt=createdAt; self.pinned=pinned
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

public enum VaultScaffoldError: Error, Equatable, Sendable {
    case invalidByteCount(Int)
    case missingValue(String)
    case noEgress(URL)
}

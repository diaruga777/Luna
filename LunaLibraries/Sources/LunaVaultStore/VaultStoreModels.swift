import Foundation
import LunaVaultBEP

/// How the iPhone reaches the Mac.
public enum VaultNetworkMode: String, Codable, Sendable, CaseIterable {
    case syncthingPublic
    case tailscale
}

/// The one paired Mac and the state of our index exchange with it.
public struct VaultPeerRecord: Equatable, Sendable {
    public var deviceID: DeviceID
    public var name: String
    public var networkMode: VaultNetworkMode
    public var manualAddresses: [VaultPeerAddress]
    public var folderID: String
    public var folderLabel: String
    /// The peer's index id and highest sequence we have applied. Sent back in
    /// ClusterConfig so the peer resumes with deltas (`§A.6`).
    public var theirIndexID: UInt64
    public var theirMaxSequence: Int64
    /// Our own index id, random and non-zero, created with the pairing.
    public var ourIndexID: UInt64
    public var pairedAt: Date
    public var lastConnectedAt: Date?

    public init(deviceID: DeviceID, name: String, networkMode: VaultNetworkMode = .syncthingPublic,
                manualAddresses: [VaultPeerAddress] = [], folderID: String = "", folderLabel: String = "",
                theirIndexID: UInt64 = 0, theirMaxSequence: Int64 = 0, ourIndexID: UInt64 = 0,
                pairedAt: Date = Date(), lastConnectedAt: Date? = nil) {
        self.deviceID = deviceID
        self.name = name
        self.networkMode = networkMode
        self.manualAddresses = manualAddresses
        self.folderID = folderID
        self.folderLabel = folderLabel
        self.theirIndexID = theirIndexID
        self.theirMaxSequence = theirMaxSequence
        self.ourIndexID = ourIndexID
        self.pairedAt = pairedAt
        self.lastConnectedAt = lastConnectedAt
    }

    public var isFolderAccepted: Bool { !folderID.isEmpty }
}

public enum VaultFileOrigin: Int, Sendable {
    /// Announced by the Mac.
    case peer = 0
    /// Created on this iPhone and not yet confirmed by the Mac's index.
    case localPending = 1
}

/// The cached full copy of a file.
public struct VaultCacheState: Equatable, Sendable {
    public var blocksHash: Data
    public var bytes: Int64
    public var lastAccess: Date
    public var pinned: Bool

    public init(blocksHash: Data, bytes: Int64, lastAccess: Date, pinned: Bool) {
        self.blocksHash = blocksHash
        self.bytes = bytes
        self.lastAccess = lastAccess
        self.pinned = pinned
    }
}

/// One row of the mirrored folder index plus this iPhone's local state.
public struct VaultFileRecord: Equatable, Sendable {
    public var name: String
    public var type: BEPFileType
    public var size: Int64
    public var modified: Date
    public var modifiedS: Int64
    public var modifiedNs: Int32
    public var modifiedBy: UInt64
    public var deleted: Bool
    public var invalid: Bool
    public var version: VersionVector
    public var sequence: Int64
    public var blockSize: Int
    public var blocksHash: Data
    /// Concatenated 32-byte block hashes. Empty for directories and tombstones.
    public var blockHashes: Data
    public var origin: VaultFileOrigin
    public var firstSeen: Date
    public var needsIndex: Bool
    public var indexedBlocksHash: Data
    public var thumbnailBlocksHash: Data
    public var cache: VaultCacheState?

    public init(name: String, type: BEPFileType, size: Int64, modifiedS: Int64, modifiedNs: Int32, modifiedBy: UInt64,
                deleted: Bool, invalid: Bool, version: VersionVector, sequence: Int64, blockSize: Int, blocksHash: Data,
                blockHashes: Data, origin: VaultFileOrigin, firstSeen: Date, needsIndex: Bool, indexedBlocksHash: Data,
                thumbnailBlocksHash: Data, cache: VaultCacheState?) {
        self.name = name
        self.type = type
        self.size = size
        self.modifiedS = modifiedS
        self.modifiedNs = modifiedNs
        modified = Date(timeIntervalSince1970: TimeInterval(modifiedS) + TimeInterval(modifiedNs) / 1_000_000_000)
        self.modifiedBy = modifiedBy
        self.deleted = deleted
        self.invalid = invalid
        self.version = version
        self.sequence = sequence
        self.blockSize = blockSize
        self.blocksHash = blocksHash
        self.blockHashes = blockHashes
        self.origin = origin
        self.firstSeen = firstSeen
        self.needsIndex = needsIndex
        self.indexedBlocksHash = indexedBlocksHash
        self.thumbnailBlocksHash = thumbnailBlocksHash
        self.cache = cache
    }

    public var blocks: [BlockInfo] {
        BlockLayout.blocks(fromConcatenatedHashes: blockHashes, fileSize: size, blockSize: blockSize)
    }

    /// Check one requested block without rebuilding the entire block list.
    public func block(atOffset offset: Int64) -> BlockInfo? {
        guard type == .file, !deleted, !invalid, blockSize > 0, offset >= 0,
              offset % Int64(blockSize) == 0, blockHashes.count % 32 == 0 else { return nil }
        let index = offset / Int64(blockSize)
        guard index < Int64(blockHashes.count / 32), offset < size || (size == 0 && offset == 0) else { return nil }
        let start = blockHashes.startIndex + Int(index) * 32
        return BlockInfo(offset: offset, size: Int32(min(Int64(blockSize), size - offset)),
                         hash: Data(blockHashes[start..<(start + 32)]))
    }

    public var displayName: String {
        name.split(separator: "/").last.map(String.init) ?? name
    }

    public var parentPath: String {
        guard let slash = name.lastIndex(of: "/") else { return "" }
        return String(name[name.startIndex..<slash])
    }

    /// True when the cached copy matches the current content.
    public var isCachedCurrent: Bool {
        guard let cache else { return false }
        return cache.blocksHash == blocksHash && !deleted
    }

    /// The wire form of this record, for the index we announce.
    public func fileInfo() -> BEPFileInfo {
        BEPFileInfo(name: name, type: type, size: size, permissions: 0, modifiedS: modifiedS, modifiedNs: modifiedNs,
                    modifiedBy: modifiedBy, deleted: deleted, invalid: invalid, noPermissions: true, version: version,
                    sequence: sequence, blockSize: Int32(blockSize), blocks: deleted ? [] : blocks, blocksHash: blocksHash)
    }
}

public enum VaultLocalChangeKind: Int, Sendable {
    case add = 0
    case delete = 1
}

/// An iPhone-originated change the Mac has not yet echoed back.
public struct VaultLocalChange: Equatable, Sendable {
    public var name: String
    public var kind: VaultLocalChangeKind
    public var version: VersionVector
    public var createdAt: Date

    public init(name: String, kind: VaultLocalChangeKind, version: VersionVector, createdAt: Date) {
        self.name = name
        self.kind = kind
        self.version = version
        self.createdAt = createdAt
    }
}

public struct VaultStoreSettings: Equatable, Sendable {
    public static let defaultCacheQuota: Int64 = 500 * 1024 * 1024
    public static let defaultScratchQuota: Int64 = 2 * 1024 * 1024 * 1024
    /// Free space that must stay untouched under either quota (decision 8).
    public static let freeSpaceReserve: Int64 = 200 * 1024 * 1024

    public var cacheQuotaBytes: Int64
    public var scratchQuotaBytes: Int64

    public init(cacheQuotaBytes: Int64 = VaultStoreSettings.defaultCacheQuota,
                scratchQuotaBytes: Int64 = VaultStoreSettings.defaultScratchQuota) {
        self.cacheQuotaBytes = cacheQuotaBytes
        self.scratchQuotaBytes = scratchQuotaBytes
    }
}

/// What applying an index batch changed, so callers can update the search
/// index, cache, and thumbnails.
public struct VaultIndexApplyResult: Equatable, Sendable {
    /// Files whose content or metadata changed and are live.
    public var changed: [String] = []
    /// Live files whose bytes changed and therefore need cache/index work.
    public var contentChanged: [String] = []
    /// Files now deleted (or turned into non-files).
    public var removed: [String] = []
    /// Local changes the peer's index confirmed.
    public var confirmed: [String] = []
    /// Files whose cached copy no longer matches and was dropped.
    public var cacheInvalidated: [String] = []
    public init() {}
}

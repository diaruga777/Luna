import Foundation
import LunaVaultBEP
import LunaVaultStore

/// The durable state needed by the iOS Syncthing runtime. Keeping this seam
/// public lets the app compose `VaultFolderStore` while deterministic tests
/// use an in-memory store.
public protocol VaultSyncStoring: AnyObject, Sendable {
    var rootURL: URL { get }
    var cacheDirectory: URL { get }
    var scratchDirectory: URL { get }
    var thumbnailDirectory: URL { get }
    var stagingDirectory: URL { get }

    func cacheFileURL(for name: String) -> URL
    func peer() throws -> VaultPeerRecord?
    func savePeer(_ peer: VaultPeerRecord) throws
    func recordConnected(at date: Date) throws
    func updateTheirIndexState(indexID: UInt64, maxSequence: Int64) throws
    func forgetTheirIndex() throws
    func applyIndex(_ index: BEPIndex, ourShortID: UInt64, now: Date) throws -> VaultIndexApplyResult
    func purgeStaleGenerations() throws -> [String]

    func stageImport(name: String, size: Int64, blockSize: Int, blocks: [BlockInfo], modified: Date,
                     ourShortID: UInt64, now: Date) throws -> VaultFileRecord
    func stageDirectory(name: String, modified: Date, ourShortID: UInt64, now: Date) throws -> VaultFileRecord
    func stageDelete(name: String, ourShortID: UInt64, now: Date) throws -> VaultFileRecord?
    func pendingLocalChanges() throws -> [VaultLocalChange]
    func announcedIndexEntries() throws -> [BEPFileInfo]
    func file(named name: String) throws -> VaultFileRecord?
    func filesNeedingIndex(limit: Int) throws -> [VaultFileRecord]
    func markIndexed(name: String, blocksHash: Data) throws
    func markThumbnail(name: String, blocksHash: Data) throws

    func recordCacheInstall(name: String, blocksHash: Data, bytes: Int64, pinned: Bool, now: Date) throws
    func markCacheAccess(name: String, now: Date) throws
    func setCachePinned(name: String, pinned: Bool) throws
    func clearCache(name: String) throws
    func cacheTotals() throws -> VaultFolderStore.CacheTotals
    func cacheEvictionCandidates() throws -> [VaultFileRecord]
    func cachedFiles() throws -> [VaultFileRecord]
    func settings() throws -> VaultStoreSettings
}

extension VaultFolderStore: VaultSyncStoring {}

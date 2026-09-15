import Foundation
import LunaVaultStore

public struct VaultCacheEvictionResult: Equatable, Sendable {
    public var effectiveQuota: Int64
    public var evictedNames: [String]

    public init(effectiveQuota: Int64, evictedNames: [String]) {
        self.effectiveQuota = effectiveQuota
        self.evictedNames = evictedNames
    }
}

/// Owns the bounded plaintext content cache. Quota is a soft ceiling around
/// pinned files: an admission is never refused, but every evictable file is
/// removed when the incoming file itself exceeds the effective quota.
public final class VaultCacheManager: @unchecked Sendable {
    public static let expirationInterval: TimeInterval = 24 * 60 * 60

    private let store: any VaultSyncStoring
    private let fileManager: FileManager
    private let availableCapacity: @Sendable (URL) -> Int64

    public init(store: any VaultSyncStoring, fileManager: FileManager = .default,
                availableCapacity: @escaping @Sendable (URL) -> Int64 = VaultCacheManager.systemAvailableCapacity) {
        self.store = store
        self.fileManager = fileManager
        self.availableCapacity = availableCapacity
    }

    public static func systemAvailableCapacity(at url: URL) -> Int64 {
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }

    public func effectiveCacheQuota() throws -> Int64 {
        let userQuota = max(0, try store.settings().cacheQuotaBytes)
        return effectiveQuota(userQuota: userQuota, at: store.cacheDirectory)
    }

    public func effectiveScratchQuota() throws -> Int64 {
        let userQuota = max(0, try store.settings().scratchQuotaBytes)
        return effectiveQuota(userQuota: userQuota, at: store.scratchDirectory)
    }

    private func effectiveQuota(userQuota: Int64, at url: URL) -> Int64 {
        let spaceAfterReserve = max(0, availableCapacity(url) - VaultStoreSettings.freeSpaceReserve)
        return min(userQuota, spaceAfterReserve)
    }

    @discardableResult
    public func prepareAdmission(bytes: Int64, replacing name: String? = nil,
                                 now: Date = Date()) throws -> VaultCacheEvictionResult {
        let incoming = max(0, bytes)
        let quota = try effectiveCacheQuota()
        let totals = try store.cacheTotals()
        let replacedBytes: Int64
        if let name, let record = try store.file(named: name) { replacedBytes = record.cache?.bytes ?? 0 }
        else { replacedBytes = 0 }
        var projected = max(0, totals.bytes - replacedBytes)
        let candidates = try store.cacheEvictionCandidates().filter { $0.name != name }
        let expiry = now.addingTimeInterval(-Self.expirationInterval)
        let expired = candidates.filter { ($0.cache?.lastAccess ?? .distantPast) <= expiry }
        let fresh = candidates.filter { ($0.cache?.lastAccess ?? .distantPast) > expiry }
        var evicted: [String] = []

        for candidate in expired + fresh {
            let mustEvictEverything = incoming > quota
            if !mustEvictEverything, projected + incoming <= quota { break }
            try remove(candidate.name)
            projected = max(0, projected - (candidate.cache?.bytes ?? 0))
            evicted.append(candidate.name)
        }
        return VaultCacheEvictionResult(effectiveQuota: quota, evictedNames: evicted)
    }

    /// Installs a completed temporary download and records it as current.
    @discardableResult
    public func install(_ temporaryURL: URL, for file: VaultFileRecord,
                        pinned: Bool = false, now: Date = Date()) throws -> URL {
        _ = try prepareAdmission(bytes: file.size, replacing: file.name, now: now)
        let destination = store.cacheFileURL(for: file.name)
        try replaceAtomically(temporaryURL, destination: destination)
        Self.protect(destination)
        do {
            try store.recordCacheInstall(name: file.name, blocksHash: file.blocksHash,
                                         bytes: file.size, pinned: pinned, now: now)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        return destination
    }

    /// Installs an imported file before its store row is created. The caller
    /// must immediately call `stageImport`; failure should be followed by
    /// `removeMaterial`.
    @discardableResult
    public func installLocalFile(_ temporaryURL: URL, name: String, bytes: Int64,
                                 now: Date = Date()) throws -> URL {
        _ = try prepareAdmission(bytes: bytes, replacing: name, now: now)
        let destination = store.cacheFileURL(for: name)
        try replaceAtomically(temporaryURL, destination: destination)
        Self.protect(destination)
        return destination
    }

    public func cachedURL(for name: String, now: Date = Date()) throws -> URL? {
        guard let record = try store.file(named: name), record.isCachedCurrent else { return nil }
        let url = store.cacheFileURL(for: name)
        guard fileManager.fileExists(atPath: url.path) else {
            try store.clearCache(name: name)
            return nil
        }
        try store.markCacheAccess(name: name, now: now)
        return url
    }

    public func setPinned(_ pinned: Bool, name: String) throws {
        try store.setCachePinned(name: name, pinned: pinned)
    }

    public func remove(_ name: String) throws {
        try removeMaterial(name)
        try store.clearCache(name: name)
    }

    /// Removes bytes even when the store already invalidated its cache state.
    public func removeMaterial(_ name: String) throws {
        let url = store.cacheFileURL(for: name)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    @discardableResult
    public func evictExpired(now: Date = Date()) throws -> [String] {
        let expiry = now.addingTimeInterval(-Self.expirationInterval)
        var removed: [String] = []
        for record in try store.cacheEvictionCandidates()
        where (record.cache?.lastAccess ?? .distantPast) <= expiry {
            try remove(record.name)
            removed.append(record.name)
        }
        return removed
    }

    @discardableResult
    public func clearUnpinned() throws -> [String] {
        var removed: [String] = []
        for record in try store.cacheEvictionCandidates() {
            try remove(record.name)
            removed.append(record.name)
        }
        return removed
    }

    private func replaceAtomically(_ source: URL, destination: URL) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: source)
        } else {
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    private static func protect(_ url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}


import CryptoKit
import Foundation
import LunaVaultModels

/// Thumbnail identity is deliberately separate from full-content cache
/// identity. A thumbnail may survive a full-content eviction, but can never
/// be reused for a different object revision or content generation.
public struct VaultThumbnailKey: Codable, Hashable, Sendable {
    public let objectID: VaultObjectID
    public let revision: UUID
    public let generation: String

    public init(objectID: VaultObjectID, revision: UUID, generation: String) {
        self.objectID = objectID
        self.revision = revision
        self.generation = generation
    }
}

public struct VaultThumbnailEntry: Codable, Hashable, Sendable {
    public let key: VaultThumbnailKey
    public let byteCount: Int64
    public let createdAt: Date
    public var lastAccessedAt: Date

    public init(key: VaultThumbnailKey, byteCount: Int64, createdAt: Date,
                lastAccessedAt: Date) {
        self.key = key
        self.byteCount = byteCount
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
    }
}

public enum VaultThumbnailError: Error, Equatable, Sendable {
    case invalidData
    case tooLarge(Int64)
    case unavailable
    case persistence
}

public struct VaultThumbnailConfiguration: Equatable, Sendable {
    public let maximumBytes: Int64
    public let quotaBytes: Int64
    public let expiry: TimeInterval

    public init(maximumBytes: Int64 = 8 * 1024 * 1024,
                quotaBytes: Int64 = 256 * 1024 * 1024,
                expiry: TimeInterval = 30 * 24 * 60 * 60) {
        self.maximumBytes = max(1, maximumBytes)
        self.quotaBytes = max(1, quotaBytes)
        self.expiry = max(1, expiry)
    }
}

/// Sidecar thumbnail store. Its metadata is one protected JSON file and its
/// payloads are opaque-ID files; no filename or source URL enters a path.
/// It has an independent quota and eviction policy from `VaultRepository`'s
/// full-content cache.
public final class VaultThumbnailStore: @unchecked Sendable {
    public let rootURL: URL
    private let fileManager: FileManager
    private let protection: VaultFileProtectionApplying
    private let configuration: VaultThumbnailConfiguration
    private let metadataURL: URL
    private let repository: VaultRepository?
    private let lock = NSLock()
    private var entriesByKey: [VaultThumbnailKey: VaultThumbnailEntry]

    public init(rootURL: URL,
                configuration: VaultThumbnailConfiguration = VaultThumbnailConfiguration(),
                fileManager: FileManager = .default,
                protectionApplier: VaultFileProtectionApplying = SystemVaultFileProtectionApplier(),
                repository: VaultRepository? = nil) throws {
        self.rootURL = rootURL
        self.configuration = configuration
        self.fileManager = fileManager
        self.protection = protectionApplier
        self.repository = repository
        self.entriesByKey = [:]
        metadataURL = rootURL.appendingPathComponent("index.json")
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try protectionApplier.apply(to: rootURL)
        if fileManager.fileExists(atPath: metadataURL.path) {
            do {
                let attrs = try fileManager.attributesOfItem(atPath: metadataURL.path)
                guard let size = (attrs[.size] as? NSNumber)?.int64Value,
                      size <= 8 * 1024 * 1024,
                      isProtected(metadataURL) else { throw VaultThumbnailError.persistence }
                let handle = try FileHandle(forReadingFrom: metadataURL)
                let data = try handle.read(upToCount: Int(size)) ?? Data()
                try handle.close()
                guard Int64(data.count) == size else { throw VaultThumbnailError.persistence }
                entriesByKey = try JSONDecoder().decode([VaultThumbnailEntry].self, from: data)
                    .reduce(into: [:]) { $0[$1.key] = $1 }
            } catch {
                entriesByKey = [:]
                try? fileManager.removeItem(at: metadataURL)
            }
        } else {
            entriesByKey = [:]
        }
        try repair()
    }

    public func put(_ data: Data, for key: VaultThumbnailKey,
                    now: Date = Date()) throws {
        guard !data.isEmpty else { throw VaultThumbnailError.invalidData }
        guard Int64(data.count) <= configuration.maximumBytes else {
            throw VaultThumbnailError.tooLarge(Int64(data.count))
        }
        try lock.withLock {
            let directory = directoryURL(for: key)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try protection.apply(to: directory)
            let destination = payloadURL(for: key)
            let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)")
            do {
                guard fileManager.createFile(atPath: staging.path, contents: nil) else {
                    throw VaultThumbnailError.persistence
                }
                try protection.apply(to: staging)
                guard isProtected(staging) else {
                    throw VaultThumbnailError.persistence
                }
                let handle = try FileHandle(forWritingTo: staging)
                try handle.write(contentsOf: data)
                try handle.synchronize(); try handle.close()
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: staging, to: destination)
                entriesByKey[key] = VaultThumbnailEntry(key: key,
                                                        byteCount: Int64(data.count),
                                                        createdAt: entriesByKey[key]?.createdAt ?? now,
                                                        lastAccessedAt: now)
                try persistIndex()
                try evictLocked(now: now)
            } catch let error as VaultThumbnailError {
                try? fileManager.removeItem(at: staging)
                throw error
            } catch {
                try? fileManager.removeItem(at: staging)
                throw VaultThumbnailError.persistence
            }
        }
    }

    /// Reading touches only the thumbnail's access timestamp; it does not
    /// pin or refresh the full-content cache.
    public func data(for key: VaultThumbnailKey, now: Date = Date()) throws -> Data? {
        try lock.withLock {
            guard let entry = entriesByKey[key] else { return nil }
            let url = payloadURL(for: key)
            guard fileManager.fileExists(atPath: url.path),
                  isProtected(url) else {
                entriesByKey.removeValue(forKey: key)
                try persistIndex()
                return nil
            }
            guard let data = fileManager.contents(atPath: url.path),
                  Int64(data.count) == entry.byteCount else {
                entriesByKey.removeValue(forKey: key)
                try persistIndex()
                return nil
            }
            if entry.lastAccessedAt != now {
                entriesByKey[key]?.lastAccessedAt = now
                try persistIndex()
            }
            return data
        }
    }

    public func entries() throws -> [VaultThumbnailEntry] {
        lock.withLock {
            entriesByKey.values.sorted {
                if $0.lastAccessedAt != $1.lastAccessedAt {
                    return $0.lastAccessedAt > $1.lastAccessedAt
                }
                return $0.key.objectID.rawValue.uuidString < $1.key.objectID.rawValue.uuidString
            }
        }
    }

    public func invalidate(_ key: VaultThumbnailKey) throws {
        try lock.withLock {
            try removeLocked(key)
            try persistIndex()
        }
    }

    /// Invalidating a revision removes all thumbnail generations for that
    /// revision, while retaining thumbnails for other object revisions.
    public func invalidate(objectID: VaultObjectID, revision: UUID? = nil) throws {
        try lock.withLock {
            let keys = entriesByKey.keys.filter {
                $0.objectID == objectID && (revision == nil || $0.revision == revision)
            }
            for key in keys { try removeLocked(key) }
            try persistIndex()
        }
    }

    public func evictExpired(now: Date = Date()) throws {
        try lock.withLock { try evictLocked(now: now); try persistIndex() }
    }

    public func evict(toByteLimit limit: Int64? = nil, now: Date = Date()) throws {
        try lock.withLock {
            let target = max(1, limit ?? configuration.quotaBytes)
            while entriesByKey.values.reduce(Int64(0), { $0 + $1.byteCount }) > target {
                guard let victim = entriesByKey.values.min(by: {
                    if $0.lastAccessedAt != $1.lastAccessedAt {
                        return $0.lastAccessedAt < $1.lastAccessedAt
                    }
                    return $0.createdAt < $1.createdAt
                }) else { break }
                try removeLocked(victim.key)
            }
            try evictLocked(now: now)
            try persistIndex()
        }
    }

    private func evictLocked(now: Date) throws {
        let cutoff = now.addingTimeInterval(-configuration.expiry)
        for entry in Array(entriesByKey.values).filter({ $0.lastAccessedAt < cutoff }) {
            try removeLocked(entry.key)
        }
        while entriesByKey.values.reduce(Int64(0), { $0 + $1.byteCount }) > configuration.quotaBytes {
            guard let victim = entriesByKey.values.min(by: {
                if $0.lastAccessedAt != $1.lastAccessedAt {
                    return $0.lastAccessedAt < $1.lastAccessedAt
                }
                return $0.createdAt < $1.createdAt
            }) else { break }
            try removeLocked(victim.key)
        }
    }

    private func removeLocked(_ key: VaultThumbnailKey) throws {
        let directory = directoryURL(for: key)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        entriesByKey.removeValue(forKey: key)
    }

    private func persistIndex() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let staging = rootURL.appendingPathComponent(".index-staging-\(UUID().uuidString)")
        do {
            guard fileManager.createFile(atPath: staging.path, contents: nil) else { throw VaultThumbnailError.persistence }
            try protection.apply(to: staging)
            guard isProtected(staging) else { throw VaultThumbnailError.persistence }
            let handle = try FileHandle(forWritingTo: staging)
            try handle.write(contentsOf: encoder.encode(Array(entriesByKey.values)))
            try handle.synchronize(); try handle.close()
            if fileManager.fileExists(atPath: metadataURL.path) {
                try fileManager.replaceItemAt(metadataURL, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: metadataURL)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw VaultThumbnailError.persistence
        }
    }

    private func repair() throws {
        for key in Array(entriesByKey.keys) {
            guard key.generation.count == 64,
                  key.generation.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                entriesByKey.removeValue(forKey: key); continue
            }
            if let repository {
                guard let object = try? repository.object(key.objectID),
                      object.revision == key.revision else {
                    entriesByKey.removeValue(forKey: key); continue
                }
            }
            let url = payloadURL(for: key)
            let attrs = try? fileManager.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if !fileManager.fileExists(atPath: url.path) || !isProtected(url) ||
                values?.isDirectory == true || values?.isSymbolicLink == true || size != entriesByKey[key]?.byteCount {
                entriesByKey.removeValue(forKey: key)
            }
        }
        // Remove orphan payload directories and files left by a killed write.
        let objectDirectories = (try? fileManager.contentsOfDirectory(at: rootURL,
                                                                        includingPropertiesForKeys: nil)) ?? []
        for objectDirectory in objectDirectories where objectDirectory != metadataURL {
            guard let revisions = try? fileManager.contentsOfDirectory(at: objectDirectory,
                                                                        includingPropertiesForKeys: nil) else {
                try? fileManager.removeItem(at: objectDirectory); continue
            }
            for revisionDirectory in revisions {
                let payloads = (try? fileManager.contentsOfDirectory(at: revisionDirectory,
                                                                      includingPropertiesForKeys: nil)) ?? []
                if payloads.isEmpty { try? fileManager.removeItem(at: revisionDirectory) }
                for payload in payloads where payload.lastPathComponent.hasPrefix(".staging-") {
                    try? fileManager.removeItem(at: payload)
                }
            }
        }
        try persistIndex()
    }

    private func directoryURL(for key: VaultThumbnailKey) -> URL {
        rootURL.appendingPathComponent(key.objectID.rawValue.uuidString, isDirectory: true)
            .appendingPathComponent(key.revision.uuidString, isDirectory: true)
    }

    private func payloadURL(for key: VaultThumbnailKey) -> URL {
        let digest = SHA256.hash(data: Data(key.generation.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directoryURL(for: key).appendingPathComponent(digest + ".thumb")
    }

    private func isProtected(_ url: URL) -> Bool {
        (try? protection.hasRequiredProtection(at: url)) == true
    }
}

public struct VaultCacheStatus: Equatable, Sendable {
    public let quotaBytes: Int64
    public let fullContentBytes: Int64
    public let entryCount: Int
    public let availableBytes: Int64

    public init(quotaBytes: Int64, fullContentBytes: Int64, entryCount: Int) {
        self.quotaBytes = quotaBytes
        self.fullContentBytes = fullContentBytes
        self.entryCount = entryCount
        availableBytes = max(0, quotaBytes - fullContentBytes)
    }
}

/// Small cache facade used by import/preview flows to make access updates
/// explicit and to apply the repository's 10%-of-capacity quota policy.
public final class VaultCacheCoordinator: @unchecked Sendable {
    private let repository: VaultRepository
    public init(repository: VaultRepository) { self.repository = repository }

    public func status() throws -> VaultCacheStatus {
        let entries = try repository.cacheEntries()
        return VaultCacheStatus(quotaBytes: repository.cacheQuotaBytes,
                                fullContentBytes: entries.filter(\.fullContent)
                                    .reduce(0) { $0 + $1.byteCount },
                                entryCount: entries.count)
    }

    public func markAccessed(_ objectID: VaultObjectID, byteCount: Int64,
                             fullContent: Bool = true, pinned: Bool = false,
                             now: Date = Date()) throws {
        guard byteCount >= 0 else { throw VaultStorageError.invalidArtifact }
        let existing = try repository.cacheEntries().first { $0.objectID == objectID }
        try repository.putCache(VaultCacheEntry(objectID: objectID, byteCount: byteCount,
                                                fullContent: fullContent,
                                                lastAccessedAt: now,
                                                createdAt: existing?.createdAt ?? now,
                                                pinned: pinned || (existing?.pinned ?? false),
                                                supportsEviction: existing?.supportsEviction ?? true), now: now)
    }

    public func evict(now: Date = Date()) throws {
        try repository.evictExpired(now: now)
    }

    public func beginPreview(_ objectID: VaultObjectID, now: Date = Date()) throws {
        try repository.setPreviewActive(objectID, active: true, now: now)
    }

    public func endPreview(_ objectID: VaultObjectID, now: Date = Date()) throws {
        try repository.setPreviewActive(objectID, active: false, now: now)
    }
}

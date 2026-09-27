import Foundation
import LunaVaultBEP
import LunaVaultStore

public protocol VaultBlockRequesting: Sendable {
    func request(folder: String, name: String, block: BlockInfo, blockNo: Int32) async throws -> Data
}

extension BEPConnection: VaultBlockRequesting {}

public enum VaultBlockDestination: Equatable, Sendable {
    case cache(pinned: Bool)
    case scratch
}

public enum VaultBlockFetchError: Error, Equatable, Sendable {
    case unavailable
    case invalidFile
    case invalidBlock(Int)
    case scratchQuotaExceeded(required: Int64, available: Int64)
}

/// Pulls and verifies one file, with at most eight outstanding BEP requests.
/// Bytes are first materialized beside their final destination and become
/// visible only after the complete file has verified.
public final class VaultBlockFetcher: @unchecked Sendable {
    public static let maximumOutstandingRequests = BEPBlockTransfer.maximumOutstandingRequests

    private let store: any VaultSyncStoring
    private let cache: VaultCacheManager
    private let fileManager: FileManager

    public init(store: any VaultSyncStoring, cache: VaultCacheManager,
                fileManager: FileManager = .default) {
        self.store = store
        self.cache = cache
        self.fileManager = fileManager
    }

    @discardableResult
    public func fetch(_ file: VaultFileRecord, folderID: String,
                      from requester: any VaultBlockRequesting,
                      to destination: VaultBlockDestination = .cache(pinned: false),
                      now: Date = Date()) async throws -> URL {
        guard file.type == .file, !file.deleted, !file.invalid,
              !file.blocks.isEmpty else { throw VaultBlockFetchError.invalidFile }
        try Task.checkCancellation()
        try BlockLayout.validate(file.blocks, fileSize: file.size)
        if destination == .scratch {
            let quota = try cache.effectiveScratchQuota()
            guard file.size <= quota else {
                throw VaultBlockFetchError.scratchQuotaExceeded(required: file.size, available: quota)
            }
        }

        let directory: URL
        switch destination {
        case .cache: directory = store.cacheDirectory
        case .scratch: directory = store.scratchDirectory
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".fetch-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
            throw VaultBlockFetchError.unavailable
        }
        var ownsTemporary = true
        defer { if ownsTemporary { try? fileManager.removeItem(at: temporary) } }
        Self.protect(temporary)
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }

        try await BEPBlockTransfer.receive(blocks: file.blocks,
            request: { index, block in
                try await requester.request(folder: folderID, name: file.name,
                                            block: block, blockNo: Int32(index))
            }, write: { _, block, bytes in
                try output.seek(toOffset: UInt64(block.offset))
                try output.write(contentsOf: bytes)
            })
        try Task.checkCancellation()
        try output.synchronize()

        switch destination {
        case .cache(let pinned):
            let installed = try cache.install(temporary, for: file, pinned: pinned, now: now)
            ownsTemporary = false
            return installed
        case .scratch:
            let key = SHA256Digest.hash(Data(file.name.utf8) + file.blocksHash)
                .map { String(format: "%02x", $0) }.joined()
            let installed = directory.appendingPathComponent(key)
            if fileManager.fileExists(atPath: installed.path) {
                _ = try fileManager.replaceItemAt(installed, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: installed)
            }
            ownsTemporary = false
            return installed
        }
    }

    private static func protect(_ url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}


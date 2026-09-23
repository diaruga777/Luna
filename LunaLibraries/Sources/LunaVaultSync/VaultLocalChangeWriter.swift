import Foundation
import LunaVaultBEP
import LunaVaultStore

public enum VaultLocalWriteError: Error, Equatable, Sendable, LocalizedError {
    case notPaired
    case sourceNotRegularFile
    case fileAlreadyExists(String)
    case deletionPending(String)
    case unsupportedEntry(String)

    public var errorDescription: String? {
        switch self {
        case .notPaired: return "Connect your Mac before importing."
        case .sourceNotRegularFile: return "Choose a regular file or folder."
        case .fileAlreadyExists(let name): return "A file or folder named \(name) already exists in Vault."
        case .deletionPending(let name): return "Wait for your Mac to confirm deletion of \(name) before importing it again."
        case .unsupportedEntry(let name): return "Vault cannot import \(name). Remove links or special items from the folder and try again."
        }
    }
}

/// Projection cleanup supplied by the indexing/UI composition root. The sync
/// tier always removes content bytes itself; search and thumbnail stores stay
/// optional package-boundary collaborators.
public struct VaultDeletionProjectionHandler: Sendable {
    public var remove: @Sendable (String) async -> Void

    public init(remove: @escaping @Sendable (String) async -> Void = { _ in }) {
        self.remove = remove
    }
}

/// Durable add/delete operations for iOS. Imports are copied through
/// `Staging`, block-hashed, installed in the pinned cache, and only then
/// announced. Existing live names are rejected because v1 has no edit path.
public final class VaultLocalChangeWriter: @unchecked Sendable {
    private let store: any VaultSyncStoring
    private let cache: VaultCacheManager
    private let localDevice: DeviceID
    private let fileManager: FileManager
    private let projections: VaultDeletionProjectionHandler

    public init(store: any VaultSyncStoring, cache: VaultCacheManager,
                localDevice: DeviceID, fileManager: FileManager = .default,
                projections: VaultDeletionProjectionHandler = VaultDeletionProjectionHandler()) {
        self.store = store
        self.cache = cache
        self.localDevice = localDevice
        self.fileManager = fileManager
        self.projections = projections
    }

    @discardableResult
    public func addFile(at sourceURL: URL, named name: String,
                        now: Date = Date()) throws -> VaultFileRecord {
        guard let peer = try store.peer(), peer.isFolderAccepted else { throw VaultLocalWriteError.notPaired }
        try BEPFileInfo.validateName(name)
        if let existing = try store.file(named: name), !existing.deleted {
            throw VaultLocalWriteError.fileAlreadyExists(name)
        }
        if try store.pendingLocalChanges().contains(where: { $0.name == name && $0.kind == .delete }) {
            throw VaultLocalWriteError.deletionPending(name)
        }
        let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw VaultLocalWriteError.sourceNotRegularFile
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attributes[.modificationDate] as? Date ?? now
        let staged = store.stagingDirectory.appendingPathComponent(".import-\(UUID().uuidString)")
        try fileManager.copyItem(at: sourceURL, to: staged)
        Self.protect(staged)
        var ownsStaged = true
        defer { if ownsStaged { try? fileManager.removeItem(at: staged) } }
        let layout = try BlockLayout.blocks(forFileAt: staged)
        _ = try cache.installLocalFile(staged, name: name, bytes: size, now: now)
        ownsStaged = false
        do {
            return try store.stageImport(
                name: name, size: size, blockSize: layout.blockSize, blocks: layout.blocks,
                modified: modified, ourShortID: localDevice.shortID, now: now)
        } catch {
            try? cache.removeMaterial(name)
            throw error
        }
    }

    @discardableResult
    public func addDirectory(named name: String, modified: Date = Date(),
                             now: Date = Date()) throws -> VaultFileRecord {
        guard let peer = try store.peer(), peer.isFolderAccepted else { throw VaultLocalWriteError.notPaired }
        try BEPFileInfo.validateName(name)
        if let existing = try store.file(named: name), !existing.deleted {
            throw VaultLocalWriteError.fileAlreadyExists(name)
        }
        if try store.pendingLocalChanges().contains(where: { $0.name == name && $0.kind == .delete }) {
            throw VaultLocalWriteError.deletionPending(name)
        }
        return try store.stageDirectory(name: name, modified: modified,
                                        ourShortID: localDevice.shortID, now: now)
    }

    @discardableResult
    public func deleteFile(named name: String, now: Date = Date()) async throws -> VaultFileRecord? {
        guard let peer = try store.peer(), peer.isFolderAccepted else { throw VaultLocalWriteError.notPaired }
        guard let tombstone = try store.stageDelete(name: name, ourShortID: localDevice.shortID, now: now) else {
            return nil
        }
        try cache.removeMaterial(name)
        await projections.remove(name)
        return tombstone
    }

    private static func protect(_ url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}

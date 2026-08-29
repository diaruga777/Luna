import Foundation
import LunaVaultCrypto

/// Durable ciphertext-only staging used by background sync. Filenames are
/// derived solely from opaque identity fields; the file contents are validated
/// authenticated envelopes before entering or leaving the store.
public final class VaultFileSyncPayloadStore: VaultSyncPayloadSource, @unchecked Sendable {
    private let rootURL: URL
    private let vaultID: String
    private let fileManager: FileManager
    private let rootKey: @Sendable (UInt32) throws -> VaultRootKey
    private let lock = NSLock()

    public init(rootURL: URL, vaultID: String,
                fileManager: FileManager = .default,
                rootKey: @escaping @Sendable (UInt32) throws -> VaultRootKey) throws {
        self.rootURL = rootURL; self.vaultID = vaultID; self.fileManager = fileManager
        self.rootKey = rootKey
        try fileManager.createDirectory(at: rootURL.appendingPathComponent("uploads", isDirectory: true),
                                        withIntermediateDirectories: true)
        try fileManager.createDirectory(at: rootURL.appendingPathComponent("downloads", isDirectory: true),
                                        withIntermediateDirectories: true)
    }

    public func stageUpload(_ payload: VaultAuthenticatedCiphertext) async throws {
        guard payload.vaultID == vaultID else { throw VaultSyncError.backend(.corruptPayload) }
        try lock.withLock { try write(payload, to: url(for: payload.identity, area: "uploads")) }
    }

    public func uploadPayload(for identity: VaultRemoteObjectIdentity) async throws -> VaultAuthenticatedCiphertext? {
        try lock.withLock { try read(identity, from: url(for: identity, area: "uploads")) }
    }

    public func installDownloadedPayload(_ payload: VaultAuthenticatedCiphertext) async throws {
        guard payload.vaultID == vaultID else { throw VaultSyncError.backend(.corruptPayload) }
        do { try payload.authenticate(rootKey: rootKey) }
        catch { throw VaultSyncError.backend(.corruptPayload) }
        try lock.withLock { try write(payload, to: url(for: payload.identity, area: "downloads")) }
    }

    public func removeStagedPayload(for identity: VaultRemoteObjectIdentity) async throws {
        try lock.withLock {
            let target = url(for: identity, area: "uploads")
            if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
        }
    }

    private func write(_ payload: VaultAuthenticatedCiphertext, to url: URL) throws {
        let data = try payload.encoded()
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
    }

    private func read(_ identity: VaultRemoteObjectIdentity, from url: URL) throws -> VaultAuthenticatedCiphertext? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try VaultAuthenticatedCiphertext.decodeAndValidate(
            Data(contentsOf: url), expected: identity, vaultID: vaultID)
    }

    private func url(for identity: VaultRemoteObjectIdentity, area: String) -> URL {
        let filename = [identity.kind.rawValue, identity.objectID.rawValue.uuidString,
                        identity.revision.uuidString, identity.generation].joined(separator: "-") + ".vault"
        return rootURL.appendingPathComponent(area, isDirectory: true).appendingPathComponent(filename)
    }
}

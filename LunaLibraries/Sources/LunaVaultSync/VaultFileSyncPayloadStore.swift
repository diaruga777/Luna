import Foundation
import LunaVaultCrypto
import LunaVaultStorage

/// Durable ciphertext-only staging used by background sync. Filenames are
/// derived solely from opaque identity fields; the file contents are validated
/// authenticated envelopes before entering or leaving the store.
public final class VaultFileSyncPayloadStore: VaultSyncPayloadSource, @unchecked Sendable {
    private let rootURL: URL
    private let vaultID: String
    private let fileManager: FileManager
    private let rootKey: @Sendable (UInt32) throws -> VaultRootKey
    private let repository: VaultRepository?
    private let lock = NSLock()

    public init(rootURL: URL, vaultID: String,
                fileManager: FileManager = .default,
                repository: VaultRepository? = nil,
                rootKey: @escaping @Sendable (UInt32) throws -> VaultRootKey) throws {
        self.rootURL = rootURL; self.vaultID = vaultID; self.fileManager = fileManager
        self.rootKey = rootKey
        self.repository = repository
        try fileManager.createDirectory(at: rootURL.appendingPathComponent("uploads", isDirectory: true),
                                        withIntermediateDirectories: true)
        try fileManager.createDirectory(at: rootURL.appendingPathComponent("downloads", isDirectory: true),
                                        withIntermediateDirectories: true)
    }

    public func stageUpload(_ payload: VaultAuthenticatedCiphertext) async throws {
        guard payload.vaultID == vaultID else { throw VaultSyncError.backend(.corruptPayload) }
        do { _ = try payload.verified(rootKey: rootKey) }
        catch { throw VaultSyncError.backend(.corruptPayload) }
        try lock.withLock { try write(payload, to: url(for: payload.identity, area: "uploads")) }
    }

    public func uploadPayload(for identity: VaultRemoteObjectIdentity) async throws -> VaultVerifiedCiphertext? {
        try lock.withLock {
            guard let payload = try read(identity, from: url(for: identity, area: "uploads")) else { return nil }
            do { return try payload.verified(rootKey: rootKey) }
            catch { throw VaultSyncError.backend(.corruptPayload) }
        }
    }

    public func installDownloadedPayload(_ payload: VaultAuthenticatedCiphertext) async throws {
        guard payload.vaultID == vaultID else { throw VaultSyncError.backend(.corruptPayload) }
        let plaintext: Data
        do { plaintext = try payload.open(rootKey: rootKey) }
        catch { throw VaultSyncError.backend(.corruptPayload) }
        try lock.withLock {
            try write(payload, to: url(for: payload.identity, area: "downloads"))
            guard let repository else { return }
            switch payload.identity.kind {
            case .content:
                guard let record = try repository.object(payload.identity.objectID),
                      !record.isTombstone, record.revision == payload.identity.revision else {
                    throw VaultSyncError.backend(.staleVersion)
                }
                _ = try repository.writeContent(plaintext, for: payload.identity.objectID)
            case .metadata,.manifest,.index:
                let kind: VaultEncryptedArtifact.Kind = payload.identity.kind == .index ? .index : .manifest
                let artifact = try VaultEncryptedArtifact(
                    kind: kind, vaultID: vaultID, revision: payload.identity.revision,
                    rootVersion: payload.rootVersion, encryptedFrames: payload.encryptedFrames)
                try repository.putEncryptedArtifact(artifact)
            }
        }
    }

    public func removeUploadPayload(for identity: VaultRemoteObjectIdentity) async throws {
        try lock.withLock {
            let target = url(for: identity, area: "uploads")
            if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
        }
    }

    public func removeAllPayloads(for identity: VaultRemoteObjectIdentity) async throws {
        try lock.withLock {
            for area in ["uploads", "downloads"] {
                let target = url(for: identity, area: area)
                if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
            }
            try repository?.removeDownloadedMaterial(for: identity)
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

import Foundation
import LunaVaultCrypto
import LunaVaultStorage

/// Durable ciphertext-only staging used by background sync. Filenames are
/// derived solely from opaque identity fields; the file contents are validated
/// authenticated envelopes before entering or leaving the store.
public final class VaultFileSyncPayloadStore: VaultStreamingSyncPayloadSource, @unchecked Sendable {
    private let rootURL: URL
    private let vaultID: String
    private let fileManager: FileManager
    private let rootKey: @Sendable (UInt32) throws -> VaultRootKey
    private let repository: VaultRepository?
    private let protection: VaultFileProtectionApplying
    private let lock = NSLock()

    public init(rootURL: URL, vaultID: String,
                fileManager: FileManager = .default,
                repository: VaultRepository? = nil,
                protectionApplier: VaultFileProtectionApplying = SystemVaultFileProtectionApplier(),
                rootKey: @escaping @Sendable (UInt32) throws -> VaultRootKey) throws {
        self.rootURL = rootURL; self.vaultID = vaultID; self.fileManager = fileManager
        self.rootKey = rootKey
        self.repository = repository
        self.protection = protectionApplier
        try fileManager.createDirectory(at: rootURL.appendingPathComponent("uploads", isDirectory: true),
                                        withIntermediateDirectories: true)
        try fileManager.createDirectory(at: rootURL.appendingPathComponent("downloads", isDirectory: true),
                                        withIntermediateDirectories: true)
        try protection.apply(to: rootURL)
        guard (try? protection.hasRequiredProtection(at: rootURL)) == true else {
            throw VaultSyncError.backend(.permissionDenied)
        }
        for area in ["uploads", "downloads"] {
            let directory = rootURL.appendingPathComponent(area, isDirectory: true)
            try protection.apply(to: directory)
            guard (try? protection.hasRequiredProtection(at: directory)) == true else {
                throw VaultSyncError.backend(.permissionDenied)
            }
        }
    }

    public func stageUpload(_ payload: VaultAuthenticatedCiphertext) async throws {
        guard payload.vaultID == vaultID else { throw VaultSyncError.backend(.corruptPayload) }
        do { _ = try payload.verified(rootKey: rootKey) }
        catch { throw VaultSyncError.backend(.corruptPayload) }
        try lock.withLock { try write(payload, to: url(for: payload.identity, area: "uploads")) }
    }

    public func stageUploadFile(_ payload: VaultAuthenticatedCiphertextFile) async throws {
        guard payload.vaultID == vaultID else { throw VaultSyncError.backend(.corruptPayload) }
        do { _ = try payload.verified(rootKey: rootKey) }
        catch { throw VaultSyncError.backend(.corruptPayload) }
        try lock.withLock { try copy(payload.fileURL, to: url(for: payload.identity, area: "uploads")) }
    }

    public func uploadPayload(for identity: VaultRemoteObjectIdentity) async throws -> VaultVerifiedCiphertext? {
        try lock.withLock {
            guard let payload = try read(identity, from: url(for: identity, area: "uploads")) else { return nil }
            do { return try payload.verified(rootKey: rootKey) }
            catch { throw VaultSyncError.backend(.corruptPayload) }
        }
    }

    public func uploadPayloadFile(for identity: VaultRemoteObjectIdentity) async throws
        -> VaultVerifiedCiphertextFile? {
        try lock.withLock {
            let destination = url(for: identity, area: "uploads")
            guard fileManager.fileExists(atPath: destination.path) else { return nil }
            do {
                return try VaultAuthenticatedCiphertextFile(
                    fileURL: destination, expectedIdentity: identity, vaultID: vaultID)
                    .verified(rootKey: rootKey)
            } catch { throw VaultSyncError.backend(.corruptPayload) }
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

    public func installDownloadedPayloadFile(_ payload: VaultAuthenticatedCiphertextFile) async throws {
        guard payload.vaultID == vaultID else { throw VaultSyncError.backend(.corruptPayload) }
        do { _ = try payload.verified(rootKey: rootKey) }
        catch { throw VaultSyncError.backend(.corruptPayload) }
        try lock.withLock {
            let destination = url(for: payload.identity, area: "downloads")
            try copy(payload.fileURL, to: destination)
            guard let repository else { return }
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent(".plaintext-\(UUID().uuidString)")
            guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
                throw VaultSyncError.backend(.io)
            }
            do {
                defer { try? fileManager.removeItem(at: temporary) }
                try protection.apply(to: temporary)
                guard (try? protection.hasRequiredProtection(at: temporary)) == true else {
                    throw VaultSyncError.backend(.permissionDenied)
                }
                _ = try payload.decrypt(to: temporary, rootKey: rootKey)
                switch payload.identity.kind {
                case .content:
                    guard let record = try repository.object(payload.identity.objectID),
                          !record.isTombstone, record.revision == payload.identity.revision else {
                        throw VaultSyncError.backend(.staleVersion)
                    }
                    _ = try repository.writeContent(from: temporary,
                                                    expectedByteCount: Int64(payload.plaintextByteCount),
                                                    for: payload.identity.objectID)
                case .metadata, .manifest, .index:
                    // Artifacts remain encrypted at rest in their repository
                    // table; they are small by construction and can use the
                    // existing artifact API after the frame file has already
                    // been authenticated and decrypted.
                    let plaintext = try Data(contentsOf: temporary)
                    let kind: VaultEncryptedArtifact.Kind = payload.identity.kind == .index ? .index : .manifest
                    _ = plaintext // metadata artifacts are installed from the authenticated envelope below.
                    let artifact = try VaultEncryptedArtifact(kind: kind, vaultID: vaultID,
                        revision: payload.identity.revision, rootVersion: payload.rootVersion,
                        encryptedFrames: try collectFrames(payload))
                    try repository.putEncryptedArtifact(artifact)
                }
            } catch let error as VaultSyncError { throw error }
            catch { throw VaultSyncError.backend(.corruptPayload) }
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

    private func copy(_ source: URL, to destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path),
              let sourceAttributes = try? fileManager.attributesOfItem(atPath: source.path),
              (sourceAttributes[.type] as? FileAttributeType) == .typeRegular else {
            throw VaultSyncError.backend(.corruptPayload)
        }
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".staging-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: staging.path, contents: nil) else {
            throw VaultSyncError.backend(.io)
        }
        do {
            try protection.apply(to: staging)
            guard (try? protection.hasRequiredProtection(at: staging)) == true else {
                throw VaultSyncError.backend(.permissionDenied)
            }
            let input = try FileHandle(forReadingFrom: source)
            let output = try FileHandle(forWritingTo: staging)
            defer { try? input.close(); try? output.close() }
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
            VaultSimulatorProtectionLedger.record(destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private func collectFrames(_ payload: VaultAuthenticatedCiphertextFile) throws -> [Data] {
        guard payload.frameCount <= 65_537 else { throw VaultSyncError.backend(.corruptPayload) }
        return try (0..<payload.frameCount).map { try payload.frame(at: $0) }
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

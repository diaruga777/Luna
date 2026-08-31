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
        try VaultSecureFileAccess.ensureDirectory(at: rootURL.appendingPathComponent("uploads", isDirectory: true))
        try VaultSecureFileAccess.ensureDirectory(at: rootURL.appendingPathComponent("downloads", isDirectory: true))
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
            Self.sweepOrphans(in: directory, fileManager: fileManager)
        }
    }

    /// A crash inside `write`/`copy` can leave a `.staging-*` partial file
    /// behind, and a crash inside `installDownloadedPayloadFile` can leave a
    /// `.plaintext-*` decrypted temporary. Both are private to this store, so
    /// a fresh launch removes any that survived rather than retaining them --
    /// notably the plaintext one, which would otherwise violate "no
    /// plaintext retained".
    private static func sweepOrphans(in directory: URL, fileManager: FileManager) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(".staging-") || name.hasPrefix(".plaintext-") else { continue }
            try? VaultSecureFileAccess.removeRegularFile(at: entry)
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
            // Nothing ever reads a downloaded object back from this store --
            // only `removeAllPayloads` cleans it up -- so it is never staged
            // here; the repository install below is this object's one durable
            // copy.
            guard let repository else { return }
            switch payload.identity.kind {
            case .content:
                guard let record = try repository.object(payload.identity.objectID),
                      !record.isTombstone, record.revision == payload.identity.revision else {
                    throw VaultSyncError.backend(.staleVersion)
                }
                let generation = try payload.verified(rootKey: rootKey).authenticatedGeneration
                _ = try repository.writeContent(plaintext, for: payload.identity.objectID,
                                                authenticatedGeneration: generation)
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
        let verified: VaultVerifiedCiphertextFile
        do { verified = try payload.verified(rootKey: rootKey) }
        catch { throw VaultSyncError.backend(.corruptPayload) }
        try lock.withLock {
            // Nothing ever reads a downloaded object back from this store --
            // only `removeAllPayloads` cleans it up -- so it is never staged
            // here; the repository install below is this object's one
            // durable copy.
            guard let repository else { return }
            do {
                switch payload.identity.kind {
                case .content:
                    guard let record = try repository.object(payload.identity.objectID),
                          !record.isTombstone, record.revision == payload.identity.revision else {
                        throw VaultSyncError.backend(.staleVersion)
                    }
                    let directory = rootURL.appendingPathComponent("downloads", isDirectory: true)
                    let temporary = directory.appendingPathComponent(".plaintext-\(UUID().uuidString)")
                    var temporaryCreated = false
                    defer {
                        if temporaryCreated { try? VaultSecureFileAccess.removeRegularFile(at: temporary) }
                    }
                    let created = try VaultSecureFileAccess.createEmptyFile(at: temporary)
                    temporaryCreated = true
                    try created.close()
                    try protection.apply(to: temporary)
                    guard (try? protection.hasRequiredProtection(at: temporary)) == true else {
                        throw VaultSyncError.backend(.permissionDenied)
                    }
                    // `decrypt` authenticates every frame while it
                    // materialises plaintext, so it is already the auth
                    // pass; the generation from the `verified()` call above
                    // is reused rather than authenticating the whole file
                    // a second time.
                    _ = try payload.decrypt(to: temporary, rootKey: rootKey)
                    _ = try repository.writeContent(from: temporary,
                                                    expectedByteCount: Int64(payload.plaintextByteCount),
                                                    for: payload.identity.objectID,
                                                    authenticatedGeneration: verified.authenticatedGeneration)
                case .metadata, .manifest, .index:
                    // Artifacts stay encrypted at rest in their repository
                    // table. Install directly from the already-authenticated
                    // envelope frames -- no plaintext temp file is needed for
                    // this kind.
                    let kind: VaultEncryptedArtifact.Kind = payload.identity.kind == .index ? .index : .manifest
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
            if fileManager.fileExists(atPath: target.path) { try VaultSecureFileAccess.removeRegularFile(at: target) }
        }
    }

    public func removeAllPayloads(for identity: VaultRemoteObjectIdentity) async throws {
        try lock.withLock {
            for area in ["uploads", "downloads"] {
                let target = url(for: identity, area: area)
                if fileManager.fileExists(atPath: target.path) { try VaultSecureFileAccess.removeRegularFile(at: target) }
            }
            try repository?.removeDownloadedMaterial(for: identity)
        }
    }

    private func write(_ payload: VaultAuthenticatedCiphertext, to url: URL) throws {
        let data = try payload.encoded()
        let parent = url.deletingLastPathComponent()
        try VaultSecureFileAccess.ensureDirectory(at: parent)
        let staging = parent.appendingPathComponent(".staging-\(UUID().uuidString)")
        var stagingCreated = false
        defer {
            if stagingCreated { try? VaultSecureFileAccess.removeRegularFile(at: staging) }
        }
        let created = try VaultSecureFileAccess.createEmptyFile(at: staging)
        stagingCreated = true
        try created.close()
        do {
            try protection.apply(to: staging)
            guard (try? protection.hasRequiredProtection(at: staging)) == true else {
                throw VaultSyncError.backend(.permissionDenied)
            }
            let output = try VaultSecureFileAccess.openForWriting(at: staging)
            try output.write(contentsOf: data)
            try output.synchronize(); try output.close()
            if fileManager.fileExists(atPath: url.path) { try VaultSecureFileAccess.removeRegularFile(at: url) }
            try VaultSecureFileAccess.install(staging, at: url)
            VaultSimulatorProtectionLedger.record(url)
        } catch {
            try? VaultSecureFileAccess.removeRegularFile(at: staging)
            throw error
        }
    }

    private func copy(_ source: URL, to destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path),
              let sourceAttributes = try? fileManager.attributesOfItem(atPath: source.path),
              (sourceAttributes[.type] as? FileAttributeType) == .typeRegular else {
            throw VaultSyncError.backend(.corruptPayload)
        }
        let parent = destination.deletingLastPathComponent()
        try VaultSecureFileAccess.ensureDirectory(at: parent)
        let staging = parent.appendingPathComponent(".staging-\(UUID().uuidString)")
        var stagingCreated = false
        defer {
            if stagingCreated { try? VaultSecureFileAccess.removeRegularFile(at: staging) }
        }
        let created = try VaultSecureFileAccess.createEmptyFile(at: staging)
        stagingCreated = true
        try created.close()
        do {
            try protection.apply(to: staging)
            guard (try? protection.hasRequiredProtection(at: staging)) == true else {
                throw VaultSyncError.backend(.permissionDenied)
            }
            let input = try VaultSecureFileAccess.openRegularReadOnly(at: source)
            let output = try VaultSecureFileAccess.openForWriting(at: staging)
            defer { try? input.close(); try? output.close() }
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
            if fileManager.fileExists(atPath: destination.path) {
                try VaultSecureFileAccess.removeRegularFile(at: destination)
            }
            try VaultSecureFileAccess.install(staging, at: destination)
            VaultSimulatorProtectionLedger.record(destination)
        } catch {
            try? VaultSecureFileAccess.removeRegularFile(at: staging)
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

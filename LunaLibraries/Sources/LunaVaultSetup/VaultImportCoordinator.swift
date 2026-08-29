import Foundation
import CryptoKit
import LunaVaultCrypto
import LunaVaultEmbeddings
import LunaVaultIndexExtraction
import LunaVaultModels
import LunaVaultSearch
import LunaVaultStorage

/// A file selected by a document picker. The URL is intentionally kept inside
/// the setup layer: no extension-facing type accepts a URL or plaintext.
public struct VaultImportSource: Sendable {
    public let fileURL: URL
    public let fileName: String?
    public let contentType: String?

    public init(fileURL: URL, fileName: String? = nil, contentType: String? = nil) {
        self.fileURL = fileURL
        self.fileName = fileName
        self.contentType = contentType
    }
}

/// Production import configuration for a remote-backed Vault. The caller
/// supplies the backend's stable identity and the app-owned root-key lookup;
/// the setup layer never invents a key or stores plaintext as an upload.
public struct VaultImportRemoteConfiguration: Sendable {
    public let backendKey: String
    public let vaultID: String
    public let root: VaultRootKey
    public let rootKey: @Sendable (UInt32) throws -> VaultRootKey
    public let chunkSize: Int
    /// The protected `uploads` directory owned by the sync payload store.
    /// When present, import copies the sealed frame file there before the job
    /// becomes visible, so a replay cannot produce a missing-payload job.
    public let payloadDirectory: URL?

    public init(backendKey: String, vaultID: String,
                chunkSize: Int = 1_048_576,
                root: VaultRootKey,
                rootKey: @escaping @Sendable (UInt32) throws -> VaultRootKey,
                payloadDirectory: URL? = nil) {
        self.backendKey = backendKey
        self.vaultID = vaultID
        self.root = root
        self.rootKey = rootKey
        self.chunkSize = min(max(1, chunkSize), 8_388_608)
        self.payloadDirectory = payloadDirectory
    }
}

public struct VaultImportConfiguration: Equatable, Sendable {
    public let deviceID: String
    public let modelVersion: String
    public let maximumBytes: Int64
    public let uploadBackendKey: String?
    public let remote: VaultImportRemoteConfiguration?

    public init(deviceID: String = "device",
                modelVersion: String = "extractor-v2",
                maximumBytes: Int64 = 100_000_000_000,
                uploadBackendKey: String? = nil,
                remote: VaultImportRemoteConfiguration? = nil) {
        self.deviceID = deviceID
        self.modelVersion = modelVersion
        self.maximumBytes = min(max(1, maximumBytes), 100_000_000_000)
        self.uploadBackendKey = uploadBackendKey
        self.remote = remote
    }

    public static func == (lhs: VaultImportConfiguration, rhs: VaultImportConfiguration) -> Bool {
        lhs.deviceID == rhs.deviceID && lhs.modelVersion == rhs.modelVersion &&
        lhs.maximumBytes == rhs.maximumBytes && lhs.uploadBackendKey == rhs.uploadBackendKey &&
        lhs.remote?.backendKey == rhs.remote?.backendKey &&
        lhs.remote?.vaultID == rhs.remote?.vaultID && lhs.remote?.chunkSize == rhs.remote?.chunkSize
    }
}

public protocol VaultImportIdentityGenerating: Sendable {
    func nextObjectID() -> VaultObjectID
    /// Returns the stable object identity for identical bytes. Legacy/custom
    /// generators may keep their existing identity behavior via the default.
    func objectID(forContentDigest digest: String) -> VaultObjectID
    func nextRevision() -> UUID
    func nextLogicalTime(now: Date) -> Int64
}

public extension VaultImportIdentityGenerating {
    func objectID(forContentDigest digest: String) -> VaultObjectID { nextObjectID() }
}

public struct SystemVaultImportIdentityGenerator: VaultImportIdentityGenerating {
    public init() {}
    public func nextObjectID() -> VaultObjectID { VaultObjectID(rawValue: UUID()) }
    public func objectID(forContentDigest digest: String) -> VaultObjectID {
        let hash = SHA256.hash(data: Data("luna-vault-object-id:\(digest)".utf8))
        let bytes = Array(hash.prefix(16))
        return VaultObjectID(rawValue: UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
            (bytes[6] & 0x0f) | 0x50, bytes[7],
            (bytes[8] & 0x3f) | 0x80, bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15])))
    }
    public func nextRevision() -> UUID { UUID() }
    public func nextLogicalTime(now: Date) -> Int64 {
        Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
    }
}

/// A compact private descriptor used by the index worker. It lives in a
/// protected app-owned sidecar because VaultObjectRecord deliberately has no
/// user-visible filename column.
public struct VaultImportedFileMetadata: Codable, Equatable, Sendable {
    public let objectID: VaultObjectID
    public let revision: UUID
    public let fileName: String
    public let contentType: String?
    public let byteCount: Int64
    public let createdAt: Date
    public let updatedAt: Date

    public init(objectID: VaultObjectID, revision: UUID, fileName: String,
                contentType: String?, byteCount: Int64, createdAt: Date,
                updatedAt: Date) {
        self.objectID = objectID
        self.revision = revision
        self.fileName = fileName
        self.contentType = contentType
        self.byteCount = byteCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public protocol VaultImportedFileMetadataStoring: Sendable {
    func put(_ metadata: VaultImportedFileMetadata) throws
    func metadata(objectID: VaultObjectID, revision: UUID) throws -> VaultImportedFileMetadata?
    func remove(objectID: VaultObjectID, revision: UUID?) throws
}

/// Metadata is keyed by opaque IDs and stored below the protected Vault
/// directory. It is not part of any extension target or extension handoff.
public final class VaultImportedFileMetadataStore: VaultImportedFileMetadataStoring, @unchecked Sendable {
    private let rootURL: URL
    private let fileManager: FileManager
    private let protection: VaultFileProtectionApplying
    private let lock = NSLock()

    public init(rootURL: URL, fileManager: FileManager = .default,
                protectionApplier: VaultFileProtectionApplying = SystemVaultFileProtectionApplier()) throws {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.protection = protectionApplier
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try protection.apply(to: rootURL)
        guard (try? protection.hasRequiredProtection(at: rootURL)) == true else {
            throw VaultImportError.protectedStaging
        }
        VaultSimulatorProtectionLedger.record(rootURL)
        try repairFiles()
    }

    public func put(_ metadata: VaultImportedFileMetadata) throws {
        try lock.withLock {
            let directory = directoryURL(for: metadata.objectID)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try protection.apply(to: directory)
            guard (try? protection.hasRequiredProtection(at: directory)) == true else {
                throw VaultImportError.protectedStaging
            }
            VaultSimulatorProtectionLedger.record(directory)
            let destination = fileURL(for: metadata.objectID, revision: metadata.revision)
            let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            do {
                guard fileManager.createFile(atPath: staging.path, contents: nil) else {
                    throw VaultImportError.protectedStaging
                }
                try protection.apply(to: staging)
                guard (try? protection.hasRequiredProtection(at: staging)) == true else {
                    throw VaultImportError.protectedStaging
                }
                VaultSimulatorProtectionLedger.record(staging)
                let handle = try FileHandle(forWritingTo: staging)
                try handle.write(contentsOf: encoder.encode(metadata))
                try handle.synchronize(); try handle.close()
                if fileManager.fileExists(atPath: destination.path) {
                    _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
                } else {
                    try fileManager.moveItem(at: staging, to: destination)
                }
                VaultSimulatorProtectionLedger.record(destination)
            } catch {
                try? fileManager.removeItem(at: staging)
                throw error
            }
        }
    }

    public func metadata(objectID: VaultObjectID, revision: UUID) throws -> VaultImportedFileMetadata? {
        try lock.withLock {
            let url = fileURL(for: objectID, revision: revision)
            guard fileManager.fileExists(atPath: url.path), isRegularProtected(url) else { return nil }
            let attrs = try fileManager.attributesOfItem(atPath: url.path)
            guard let size = (attrs[.size] as? NSNumber)?.int64Value, size <= 1_048_576 else {
                throw VaultImportError.malformedJournal
            }
            let handle = try VaultSecureFileAccess.openRegularReadOnly(at: url)
            defer { try? handle.close() }
            guard let data = try handle.read(upToCount: Int(size)), Int64(data.count) == size else {
                throw VaultImportError.malformedJournal
            }
            return try JSONDecoder().decode(VaultImportedFileMetadata.self, from: data)
        }
    }

    public func remove(objectID: VaultObjectID, revision: UUID? = nil) throws {
        try lock.withLock {
            let directory = directoryURL(for: objectID)
            guard fileManager.fileExists(atPath: directory.path) else { return }
            if let revision {
                let url = fileURL(for: objectID, revision: revision)
                if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            } else {
                try fileManager.removeItem(at: directory)
            }
        }
    }

    private func directoryURL(for objectID: VaultObjectID) -> URL {
        rootURL.appendingPathComponent(objectID.rawValue.uuidString, isDirectory: true)
    }

    private func fileURL(for objectID: VaultObjectID, revision: UUID) -> URL {
        directoryURL(for: objectID).appendingPathComponent(revision.uuidString + ".json")
    }

    private func isRegularProtected(_ url: URL) -> Bool {
        guard (try? protection.hasRequiredProtection(at: url)) == true,
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory != true, values.isSymbolicLink != true else { return false }
        return true
    }

    private func repairFiles() throws {
        let children = (try? fileManager.contentsOfDirectory(at: rootURL,
                                                              includingPropertiesForKeys: nil)) ?? []
        for child in children {
            guard UUID(uuidString: child.lastPathComponent) != nil else {
                try? fileManager.removeItem(at: child)
                continue
            }
            guard let files = try? fileManager.contentsOfDirectory(at: child,
                                                                    includingPropertiesForKeys: nil) else {
                try? fileManager.removeItem(at: child); continue
            }
            for file in files {
                let revision = file.deletingPathExtension().lastPathComponent
                let attrs = try? fileManager.attributesOfItem(atPath: file.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? Int64.max
                guard file.pathExtension == "json",
                      UUID(uuidString: revision) != nil,
                      size <= 1_048_576,
                      isRegularProtected(file) else {
                    try? fileManager.removeItem(at: file)
                    continue
                }
            }
        }
    }
}

public enum VaultImportError: Error, Equatable, Sendable {
    case invalidURL
    case notAFile
    case symbolicLink
    case inputTooLarge(Int64)
    case protectedStaging
    case interrupted
    case missingObject
    case invalidSource
    case securityScopeRequired
    case malformedJournal
    case remoteConfigurationRequired
    case cleanupFailed
}

public struct VaultImportResult: Equatable, Sendable {
    public let objectID: VaultObjectID
    public let revision: UUID
    public let logicalTime: Int64
    public let fileName: String
    public let byteCount: Int64
    public let indexJobID: UUID?
    public let uploadJobID: UUID?

    public init(objectID: VaultObjectID, revision: UUID, logicalTime: Int64,
                fileName: String, byteCount: Int64, indexJobID: UUID?, uploadJobID: UUID?) {
        self.objectID = objectID
        self.revision = revision
        self.logicalTime = logicalTime
        self.fileName = fileName
        self.byteCount = byteCount
        self.indexJobID = indexJobID
        self.uploadJobID = uploadJobID
    }
}

private struct VaultImportJournal: Codable, Sendable {
    let objectID: VaultObjectID
    let revision: UUID
    let logicalTime: Int64
    let deviceID: String
    let fileName: String
    let contentType: String?
    let byteCount: Int64
    let createdAt: Date
    let updatedAt: Date
    let sourceName: String
    let contentDigest: String
    let remoteGeneration: String?

    private enum CodingKeys: String, CodingKey {
        case objectID, revision, logicalTime, deviceID, fileName, contentType,
             byteCount, createdAt, updatedAt, sourceName, contentDigest, remoteGeneration
    }

    init(objectID: VaultObjectID, revision: UUID, logicalTime: Int64,
         deviceID: String, fileName: String, contentType: String?, byteCount: Int64,
         createdAt: Date, updatedAt: Date, sourceName: String, contentDigest: String,
         remoteGeneration: String? = nil) {
        self.objectID = objectID; self.revision = revision; self.logicalTime = logicalTime
        self.deviceID = deviceID; self.fileName = fileName; self.contentType = contentType
        self.byteCount = byteCount; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.sourceName = sourceName
        self.contentDigest = contentDigest
        self.remoteGeneration = remoteGeneration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        objectID = try c.decode(VaultObjectID.self, forKey: .objectID)
        revision = try c.decode(UUID.self, forKey: .revision)
        logicalTime = try c.decode(Int64.self, forKey: .logicalTime)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        fileName = try c.decode(String.self, forKey: .fileName)
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
        byteCount = try c.decode(Int64.self, forKey: .byteCount)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        sourceName = try c.decode(String.self, forKey: .sourceName)
        contentDigest = try c.decode(String.self, forKey: .contentDigest)
        remoteGeneration = try c.decodeIfPresent(String.self, forKey: .remoteGeneration)
    }
}

/// Imports a security-scoped file through a protected, opaque staging journal.
/// The journal is removed only after the object, metadata, and durable work
/// records exist, so a process death can be repaired on the next launch.
public final class VaultImportCoordinator: @unchecked Sendable {
    public let stagingDirectory: URL
    private let repository: VaultRepository
    private let metadataStore: VaultImportedFileMetadataStoring
    private let configuration: VaultImportConfiguration
    private let identity: VaultImportIdentityGenerating
    private let fileManager: FileManager
    private let protection: VaultFileProtectionApplying
    private let lock = NSLock()

    public init(repository: VaultRepository,
                metadataStore: VaultImportedFileMetadataStoring? = nil,
                configuration: VaultImportConfiguration = VaultImportConfiguration(),
                identity: VaultImportIdentityGenerating = SystemVaultImportIdentityGenerator(),
                fileManager: FileManager = .default,
                protectionApplier: VaultFileProtectionApplying = SystemVaultFileProtectionApplier()) throws {
        self.repository = repository
        self.configuration = configuration
        self.identity = identity
        self.fileManager = fileManager
        self.protection = protectionApplier
        let root = repository.contentDirectory.deletingLastPathComponent()
            .appendingPathComponent("VaultImportStaging", isDirectory: true)
        self.stagingDirectory = root
        self.metadataStore = try metadataStore ?? VaultImportedFileMetadataStore(
            rootURL: root.appendingPathComponent("Metadata", isDirectory: true),
            fileManager: fileManager, protectionApplier: protectionApplier)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try protection.apply(to: root)
        guard (try? protection.hasRequiredProtection(at: root)) == true else {
            throw VaultImportError.protectedStaging
        }
        VaultSimulatorProtectionLedger.record(root)
    }

    /// Imports one source file. Reading is bounded by `maximumBytes`; the
    /// source is never opened by a background/network or extension target.
    public func importFile(_ source: VaultImportSource, now: Date = Date()) throws -> VaultImportResult {
        try lock.withLock {
            guard source.fileURL.isFileURL else { throw VaultImportError.invalidURL }
            let scoped = source.fileURL.startAccessingSecurityScopedResource()
            // URLs created by the app itself are already authorized. Every
            // external document-provider URL must carry a live security scope;
            // this avoids a TOCTOU read after the picker lease expires.
            let appOwned = isInsideRepositoryContainer(source.fileURL)
            guard scoped || appOwned else { throw VaultImportError.securityScopeRequired }
            defer { if scoped { source.fileURL.stopAccessingSecurityScopedResource() } }
            guard isRegularFile(source.fileURL) else { throw VaultImportError.notAFile }
            let values = try source.fileURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .nameKey])
            guard values.isDirectory != true else { throw VaultImportError.notAFile }
            guard values.isSymbolicLink != true else { throw VaultImportError.symbolicLink }
            let attrs = try fileManager.attributesOfItem(atPath: source.fileURL.path)
            let sourceHandle = try VaultSecureFileAccess.openRegularReadOnly(at: source.fileURL)
            defer { try? sourceHandle.close() }
            let descriptorSize = try sourceHandle.seekToEnd()
            try sourceHandle.seek(toOffset: 0)
            guard let rawSize = (attrs[.size] as? NSNumber)?.int64Value,
                  rawSize == Int64(descriptorSize) else { throw VaultImportError.invalidSource }
            let byteCount = rawSize
            guard byteCount >= 0 else { throw VaultImportError.invalidSource }
            guard byteCount <= configuration.maximumBytes else { throw VaultImportError.inputTooLarge(byteCount) }

            // Hash through the source descriptor before choosing its opaque
            // identity. This is streaming-only and makes retries of identical
            // bytes converge on one object without retaining plaintext.
            let contentDigest = try digestFile(sourceHandle, expectedByteCount: byteCount)
            try sourceHandle.seek(toOffset: 0)
            let objectID = identity.objectID(forContentDigest: contentDigest)
            let revision = identity.nextRevision()
            let logicalTime = identity.nextLogicalTime(now: now)
            let fileName = sanitizedFileName(source.fileName ?? values.name ?? source.fileURL.lastPathComponent)
            guard !fileName.isEmpty else { throw VaultImportError.invalidSource }
            var journal = VaultImportJournal(objectID: objectID, revision: revision,
                                             logicalTime: logicalTime, deviceID: configuration.deviceID,
                                             fileName: fileName, contentType: source.contentType,
                                             byteCount: byteCount, createdAt: now, updatedAt: now,
                                             sourceName: source.fileURL.lastPathComponent,
                                             contentDigest: contentDigest)
            let token = UUID().uuidString
            let staged = stagingDirectory.appendingPathComponent("payload-\(token)")
            let marker = stagingDirectory.appendingPathComponent("journal-\(token).json")
            // The journal is the recovery anchor and is durably written before
            // any plaintext enters Vault's staging area.
            try writeJournal(journal, to: marker)
            try stage(sourceHandle, to: staged, expectedByteCount: byteCount,
                      expectedDigest: contentDigest)

            let remoteStaged: URL?
            if let remote = configuration.remote {
                let destination = stagingDirectory.appendingPathComponent("ciphertext-\(token).lvf")
                let encrypted = try sealRemotePayload(staged, to: destination, journal: journal,
                                                       remote: remote)
                let payloadDirectory = remote.payloadDirectory ??
                    stagingDirectory.deletingLastPathComponent()
                        .appendingPathComponent("VaultSyncCiphertext/uploads", isDirectory: true)
                try stageRemoteUpload(encrypted, from: destination, into: payloadDirectory)
                remoteStaged = destination
                journal = VaultImportJournal(objectID: journal.objectID, revision: journal.revision,
                    logicalTime: journal.logicalTime, deviceID: journal.deviceID,
                    fileName: journal.fileName, contentType: journal.contentType,
                    byteCount: journal.byteCount, createdAt: journal.createdAt,
                    updatedAt: journal.updatedAt, sourceName: journal.sourceName,
                    contentDigest: journal.contentDigest, remoteGeneration: encrypted.identity.generation)
                // Persist the ciphertext generation in the recovery anchor
                // before the atomic object/job boundary is attempted.
                try writeJournal(journal, to: marker)
            } else {
                remoteStaged = nil
            }

            do {
                let result = try finalize(journal, stagedURL: staged, journalURL: marker,
                                          remoteURL: remoteStaged)
                do {
                    try fileManager.removeItem(at: staged)
                    if let remoteStaged { try fileManager.removeItem(at: remoteStaged) }
                    try fileManager.removeItem(at: marker)
                } catch { throw VaultImportError.cleanupFailed }
                return result
            } catch {
                // Leave both protected files for repair. The import job is
                // durable once finalize has reached the repository boundary.
                throw error
            }
        }
    }

    /// Replays protected journals left by a killed/import-expired process and
    /// removes only stale staging pairs that cannot be matched to a journal.
    @discardableResult
    public func repairInterruptedImports() throws -> [VaultImportResult] {
        try lock.withLock {
            let files = (try? fileManager.contentsOfDirectory(at: stagingDirectory,
                                                               includingPropertiesForKeys: nil)) ?? []
            var results: [VaultImportResult] = []
            var livePayloadTokens = Set<String>()
            var liveCiphertextTokens = Set<String>()
            var cleanupFailed = false
            for journalURL in files where journalURL.lastPathComponent.hasPrefix("journal-") && journalURL.pathExtension == "json" {
                let token = journalURL.deletingPathExtension().lastPathComponent
                    .dropFirst("journal-".count)
                guard UUID(uuidString: String(token)) != nil,
                      isProtected(journalURL), isRegularFile(journalURL),
                      let attrs = try? fileManager.attributesOfItem(atPath: journalURL.path),
                      let journalSize = (attrs[.size] as? NSNumber)?.int64Value,
                      journalSize <= 1_048_576,
                      let journalData = try? readBounded(journalURL, maximumBytes: 1_048_576),
                      let journal = try? JSONDecoder().decode(VaultImportJournal.self, from: journalData),
                      valid(journal) else {
                    try? fileManager.removeItem(at: journalURL)
                    let tokenString = String(token)
                    if UUID(uuidString: tokenString) != nil {
                        try? fileManager.removeItem(at: stagingDirectory.appendingPathComponent("payload-\(tokenString)"))
                    }
                    continue
                }
                let tokenString = String(token)
                let payload = stagingDirectory.appendingPathComponent("payload-\(tokenString)")
                guard fileManager.fileExists(atPath: payload.path), isProtected(payload),
                      isRegularFile(payload) else {
                    try? fileManager.removeItem(at: journalURL)
                    try? fileManager.removeItem(at: payload)
                    continue
                }
                livePayloadTokens.insert(tokenString)
                let ciphertext = stagingDirectory.appendingPathComponent("ciphertext-\(tokenString).lvf")
                let remoteURL: URL?
                if configuration.remote != nil {
                    guard fileManager.fileExists(atPath: ciphertext.path),
                          isProtected(ciphertext), isRegularFile(ciphertext) else {
                        continue
                    }
                    liveCiphertextTokens.insert(tokenString)
                    remoteURL = ciphertext
                } else {
                    remoteURL = nil
                }
                var resolvedJournal = journal
                if let remote = configuration.remote, let remoteURL, journal.remoteGeneration == nil,
                   let encrypted = try? VaultAuthenticatedCiphertextFile(fileURL: remoteURL,
                                                                          vaultID: remote.vaultID),
                   encrypted.identity.objectID == journal.objectID,
                   encrypted.identity.revision == journal.revision,
                   encrypted.identity.kind == .content,
                   encrypted.plaintextByteCount == UInt64(journal.byteCount) {
                    do {
                        _ = try encrypted.verified(rootKey: remote.rootKey)
                        resolvedJournal = VaultImportJournal(objectID: journal.objectID,
                            revision: journal.revision, logicalTime: journal.logicalTime,
                            deviceID: journal.deviceID, fileName: journal.fileName,
                            contentType: journal.contentType, byteCount: journal.byteCount,
                            createdAt: journal.createdAt, updatedAt: journal.updatedAt,
                            sourceName: journal.sourceName, contentDigest: journal.contentDigest,
                            remoteGeneration: encrypted.identity.generation)
                        try writeJournal(resolvedJournal, to: journalURL)
                    } catch { continue }
                }
                do {
                    let result = try finalize(resolvedJournal, stagedURL: payload, journalURL: journalURL,
                                              remoteURL: remoteURL)
                    do {
                        try fileManager.removeItem(at: payload)
                        if let remoteURL { try fileManager.removeItem(at: remoteURL) }
                        try fileManager.removeItem(at: journalURL)
                    } catch {
                        cleanupFailed = true
                    }
                    results.append(result)
                } catch {
                    // A later foreground/background pass can retry the same
                    // protected journal without losing the source bytes.
                    continue
                }
            }
            // A crash can leave a payload, malformed journal, or an old
            // temporary file behind. The staging directory is private to this
            // coordinator, so sweep everything not paired with a valid live
            // journal rather than retaining unbounded plaintext.
            for file in files {
                let name = file.lastPathComponent
                if name.hasPrefix("payload-") {
                    let token = String(name.dropFirst("payload-".count))
                    if UUID(uuidString: token) == nil || !livePayloadTokens.contains(token) {
                        do { try fileManager.removeItem(at: file) }
                        catch { cleanupFailed = true }
                    }
                } else if name.hasPrefix("ciphertext-") && name.hasSuffix(".lvf") {
                    let token = String(name.dropFirst("ciphertext-".count).dropLast(".lvf".count))
                    if UUID(uuidString: token) == nil || !liveCiphertextTokens.contains(token) {
                        do { try fileManager.removeItem(at: file) }
                        catch { cleanupFailed = true }
                    }
                } else if name.hasPrefix(".staging-") || name.hasPrefix("tmp-") {
                    do { try fileManager.removeItem(at: file) }
                    catch { cleanupFailed = true }
                }
            }
            if cleanupFailed { throw VaultImportError.cleanupFailed }
            return results
        }
    }

    private func finalize(_ journal: VaultImportJournal, stagedURL: URL, journalURL: URL,
                          remoteURL: URL? = nil) throws -> VaultImportResult {
        guard fileManager.fileExists(atPath: stagedURL.path), isProtected(stagedURL),
              isRegularFile(stagedURL) else {
            throw VaultImportError.protectedStaging
        }
        let attrs = try fileManager.attributesOfItem(atPath: stagedURL.path)
        guard let stagedSize = (attrs[.size] as? NSNumber)?.int64Value,
              stagedSize == journal.byteCount else { throw VaultImportError.interrupted }
        guard journal.contentDigest.count == 64,
              journal.contentDigest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              try digestFile(stagedURL, expectedByteCount: journal.byteCount) == journal.contentDigest else {
            throw VaultImportError.interrupted
        }
        let remoteIdentity: VaultRemoteObjectIdentity?
        if let remote = configuration.remote {
            guard let remoteURL,
                  journal.remoteGeneration?.count == 64,
                  let payload = try? VaultAuthenticatedCiphertextFile(
                    fileURL: remoteURL, vaultID: remote.vaultID),
                  payload.identity.objectID == journal.objectID,
                  payload.identity.revision == journal.revision,
                  payload.identity.kind == .content,
                  payload.plaintextByteCount == UInt64(journal.byteCount),
                  payload.identity.generation == journal.remoteGeneration else {
                throw VaultImportError.interrupted
            }
            do { _ = try payload.verified(rootKey: remote.rootKey) }
            catch { throw VaultImportError.interrupted }
            remoteIdentity = payload.identity
        } else {
            guard configuration.uploadBackendKey == nil else {
                throw VaultImportError.remoteConfigurationRequired
            }
            remoteIdentity = nil
        }
        if let duplicate = try existingDuplicateResult(for: journal) {
            return duplicate
        }
        let record = VaultObjectRecord(id: journal.objectID, revision: journal.revision,
                                       logicalTime: journal.logicalTime, size: journal.byteCount,
                                       contentType: journal.contentType, createdAt: journal.createdAt,
                                       updatedAt: journal.updatedAt, accessedAt: journal.updatedAt,
                                       deviceID: journal.deviceID)
        let indexKey = "index:\(journal.objectID.rawValue.uuidString):\(journal.revision.uuidString):\(configuration.modelVersion)"
        let indexJob = VaultJob(kind: .index, objectID: journal.objectID,
                                createdAt: journal.updatedAt, updatedAt: journal.updatedAt,
                                idempotencyKey: indexKey, revision: journal.revision)
        var jobs = [indexJob]
        var uploadID: UUID?
        if let backendKey = configuration.remote?.backendKey {
            // The content generation is filled by the authenticated content
            // install. The upload worker must still bind its request to this
            // revision; it may not use a random or all-zero dedupe token.
            guard let remoteIdentity else { throw VaultImportError.remoteConfigurationRequired }
            let upload = VaultJob(kind: .upload, objectID: journal.objectID,
                                  createdAt: journal.updatedAt, updatedAt: journal.updatedAt,
                                  idempotencyKey: "upload:\(backendKey):content:\(journal.objectID.rawValue.uuidString):\(journal.revision.uuidString):\(remoteIdentity.generation)",
                                  revision: journal.revision, backendKey: backendKey,
                                  payloadGeneration: remoteIdentity.generation, remoteObjectKind: "content")
            jobs.append(upload)
            uploadID = upload.id
        }
        _ = try repository.insertAtomically(VaultAtomicObjectInsertRequest(record: record,
                                                                            contentURL: stagedURL,
                                                                            contentByteCount: journal.byteCount,
                                                                            jobs: jobs,
                                                                            deferVisibility: true))
        guard let current = try repository.object(journal.objectID), current.revision == journal.revision,
              !current.isTombstone else { throw VaultImportError.missingObject }
        try metadataStore.put(VaultImportedFileMetadata(objectID: journal.objectID,
                                                         revision: journal.revision,
                                                         fileName: journal.fileName,
                                                         contentType: journal.contentType,
                                                         byteCount: journal.byteCount,
                                                         createdAt: journal.createdAt,
                                                         updatedAt: journal.updatedAt))
        // Publish only after the protected sidecar and the durable jobs exist;
        // an index worker can now never observe an incomplete import.
        try repository.setObjectReady(journal.objectID)
        let storedIndexID = try repository.job(idempotencyKey: indexKey)?.id ?? indexJob.id
        let storedUploadID = uploadID.flatMap { id in
            try? repository.job(id)?.id
        } ?? uploadID
        return VaultImportResult(objectID: journal.objectID, revision: journal.revision,
                                 logicalTime: journal.logicalTime, fileName: journal.fileName,
                                 byteCount: journal.byteCount, indexJobID: storedIndexID,
                                 uploadJobID: storedUploadID)
    }

    /// The system identity is content-addressed while revisions remain
    /// per-import metadata. A retry with a fresh revision must converge on the
    /// already-installed object instead of being mistaken for a conflicting
    /// update by the atomic insert boundary.
    private func existingDuplicateResult(for journal: VaultImportJournal) throws -> VaultImportResult? {
        guard let current = try repository.object(journal.objectID),
              !current.isTombstone, current.revision != journal.revision,
              let capability = try repository.localContentCapability(for: journal.objectID),
              capability.revision == current.revision,
              capability.generation == journal.contentDigest,
              capability.byteCount == journal.byteCount else { return nil }

        let metadata: VaultImportedFileMetadata
        if let existing = try metadataStore.metadata(objectID: journal.objectID,
                                                      revision: current.revision) {
            metadata = existing
        } else {
            let recovered = VaultImportedFileMetadata(
                objectID: journal.objectID, revision: current.revision,
                fileName: journal.fileName, contentType: journal.contentType,
                byteCount: current.size, createdAt: journal.createdAt,
                updatedAt: journal.updatedAt)
            try metadataStore.put(recovered)
            metadata = recovered
        }
        try repository.setObjectReady(journal.objectID)

        var jobs = try repository.jobs().filter {
            $0.objectID == journal.objectID && $0.revision == current.revision
        }
        var indexJob = jobs.first(where: { $0.kind == .index &&
                                           $0.idempotencyKey.hasSuffix(":\(configuration.modelVersion)") })
        if indexJob == nil {
            let job = VaultJob(kind: .index, objectID: journal.objectID,
                               createdAt: journal.updatedAt, updatedAt: journal.updatedAt,
                               idempotencyKey: "index:\(journal.objectID.rawValue.uuidString):\(current.revision.uuidString):\(configuration.modelVersion)",
                               revision: current.revision)
            try repository.enqueue(job)
            indexJob = try repository.job(idempotencyKey: job.idempotencyKey)
        }

        let backendKey = configuration.remote?.backendKey
        var uploadJob = jobs.first(where: { $0.kind == .upload &&
                                            $0.backendKey == backendKey })
        if let backendKey, uploadJob == nil {
            guard let generation = journal.remoteGeneration else {
                throw VaultImportError.remoteConfigurationRequired
            }
            let job = VaultJob(kind: .upload, objectID: journal.objectID,
                               createdAt: journal.updatedAt, updatedAt: journal.updatedAt,
                               idempotencyKey: "upload:\(backendKey):content:\(journal.objectID.rawValue.uuidString):\(current.revision.uuidString):\(generation)",
                               revision: current.revision, backendKey: backendKey,
                               payloadGeneration: generation,
                               remoteObjectKind: "content")
            try repository.enqueue(job)
            uploadJob = try repository.job(idempotencyKey: job.idempotencyKey)
        }
        return VaultImportResult(objectID: journal.objectID, revision: current.revision,
                                 logicalTime: current.logicalTime, fileName: metadata.fileName,
                                 byteCount: current.size, indexJobID: indexJob?.id,
                                 uploadJobID: uploadJob?.id)
    }

    private func stage(_ input: FileHandle, to destination: URL, expectedByteCount: Int64,
                       expectedDigest: String) throws {
        do {
            guard fileManager.createFile(atPath: destination.path, contents: nil) else {
                throw VaultImportError.protectedStaging
            }
            try protection.apply(to: destination)
            guard isProtected(destination) else { throw VaultImportError.protectedStaging }
            // Keep the source descriptor open for the whole copy. A later
            // replacement of the source pathname cannot switch the bytes
            // being copied midway through the import.
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var copied: Int64 = 0
            var hasher = SHA256()
            while copied < expectedByteCount {
                guard let chunk = try input.read(upToCount: Int(min(1_048_576, expectedByteCount - copied))),
                      !chunk.isEmpty else { throw VaultImportError.interrupted }
                try output.write(contentsOf: chunk)
                hasher.update(data: chunk)
                copied += Int64(chunk.count)
            }
            guard (try input.read(upToCount: 1)?.isEmpty != false) else {
                throw VaultImportError.interrupted
            }
            try output.synchronize()
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == expectedDigest else { throw VaultImportError.interrupted }
            guard isProtected(destination) else { throw VaultImportError.protectedStaging }
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    private func sealRemotePayload(_ plaintextURL: URL, to destination: URL,
                                   journal: VaultImportJournal,
                                   remote: VaultImportRemoteConfiguration)
        throws -> VaultAuthenticatedCiphertextFile {
        guard remote.vaultID.isEmpty == false,
              remote.backendKey.isEmpty == false,
              journal.byteCount >= 0 else { throw VaultImportError.remoteConfigurationRequired }
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw VaultImportError.protectedStaging
        }
        do {
            // The output inode is protected before the first ciphertext/header
            // byte is written. Atomic install is still performed by the sync
            // payload store after this authenticated file is copied.
            try protection.apply(to: destination)
            guard isProtected(destination) else { throw VaultImportError.protectedStaging }
            let payload = try VaultAuthenticatedCiphertextFile.seal(
                plaintextURL: plaintextURL, fileURL: destination,
                vaultID: remote.vaultID, kind: .content,
                objectID: journal.objectID, revision: journal.revision,
                root: remote.root, chunkSize: remote.chunkSize)
            _ = try payload.verified(rootKey: remote.rootKey)
            guard payload.plaintextByteCount == UInt64(journal.byteCount) else {
                throw VaultImportError.interrupted
            }
            VaultSimulatorProtectionLedger.record(destination)
            return payload
        } catch let error as VaultImportError {
            try? fileManager.removeItem(at: destination)
            throw error
        } catch {
            try? fileManager.removeItem(at: destination)
            throw VaultImportError.interrupted
        }
    }

    private func stageRemoteUpload(_ payload: VaultAuthenticatedCiphertextFile,
                                   from source: URL, into directory: URL) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try protection.apply(to: directory)
        guard isProtected(directory) else { throw VaultImportError.protectedStaging }
        let filename = [payload.identity.kind.rawValue,
                        payload.identity.objectID.rawValue.uuidString,
                        payload.identity.revision.uuidString,
                        payload.identity.generation].joined(separator: "-") + ".vault"
        let destination = directory.appendingPathComponent(filename)
        let staging = directory.appendingPathComponent(".import-upload-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: staging.path, contents: nil) else {
            throw VaultImportError.protectedStaging
        }
        do {
            try protection.apply(to: staging)
            guard isProtected(staging) else { throw VaultImportError.protectedStaging }
            let input = try VaultSecureFileAccess.openRegularReadOnly(at: source)
            let output = try FileHandle(forWritingTo: staging)
            defer { try? input.close(); try? output.close() }
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
            VaultSimulatorProtectionLedger.record(destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private func valid(_ journal: VaultImportJournal) -> Bool {
        guard journal.byteCount >= 0, journal.byteCount <= configuration.maximumBytes,
              !journal.deviceID.isEmpty, journal.deviceID.utf8.count <= 256,
              !journal.fileName.isEmpty, journal.fileName.utf8.count <= 4_096,
              sanitizedFileName(journal.fileName) == journal.fileName,
              journal.sourceName.utf8.count <= 4_096,
              journal.contentDigest.count == 64,
              journal.contentDigest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return false }
        return true
    }

    private func digestFile(_ url: URL, expectedByteCount: Int64) throws -> String {
        let handle = try VaultSecureFileAccess.openRegularReadOnly(at: url)
        defer { try? handle.close() }
        return try digestFile(handle, expectedByteCount: expectedByteCount)
    }

    private func digestFile(_ handle: FileHandle, expectedByteCount: Int64) throws -> String {
        guard expectedByteCount >= 0 else { throw VaultImportError.invalidSource }
        try handle.seek(toOffset: 0)
        var remaining = expectedByteCount
        var hasher = SHA256()
        while remaining > 0 {
            guard let chunk = try handle.read(upToCount: Int(min(1_048_576, remaining))),
                  !chunk.isEmpty else { throw VaultImportError.interrupted }
            hasher.update(data: chunk)
            remaining -= Int64(chunk.count)
        }
        guard (try handle.read(upToCount: 1)?.isEmpty != false) else {
            throw VaultImportError.invalidSource
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func readBounded(_ url: URL, maximumBytes: Int64) throws -> Data {
        let handle = try VaultSecureFileAccess.openRegularReadOnly(at: url)
        defer { try? handle.close() }
        var data = Data()
        var remaining = maximumBytes
        while remaining > 0 {
            guard let chunk = try handle.read(upToCount: Int(min(1_048_576, remaining))),
                  !chunk.isEmpty else { break }
            data.append(chunk)
            remaining -= Int64(chunk.count)
        }
        guard (try handle.read(upToCount: 1)?.isEmpty != false) else {
            throw VaultImportError.malformedJournal
        }
        return data
    }

    private func writeJournal(_ journal: VaultImportJournal, to destination: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw VaultImportError.protectedStaging
        }
        do {
            try protection.apply(to: destination)
            guard isProtected(destination) else { throw VaultImportError.protectedStaging }
            let handle = try FileHandle(forWritingTo: destination)
            try handle.write(contentsOf: encoder.encode(journal))
            try handle.synchronize(); try handle.close()
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    private func sanitizedFileName(_ value: String) -> String {
        let basename = URL(fileURLWithPath: value).lastPathComponent
        return basename.replacingOccurrences(of: "\0", with: "")
    }

    private func isProtected(_ url: URL) -> Bool {
        (try? protection.hasRequiredProtection(at: url)) == true
    }

    private func isRegularFile(_ url: URL) -> Bool {
        guard url.isFileURL,
              let handle = try? VaultSecureFileAccess.openRegularReadOnly(at: url) else { return false }
        defer { try? handle.close() }
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory != true, values.isSymbolicLink != true,
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType,
              type == .typeRegular else { return false }
        return true
    }

    private func isInsideRepositoryContainer(_ source: URL) -> Bool {
        let base = repository.contentDirectory.deletingLastPathComponent()
            .standardizedFileURL.path
        let candidate = source.standardizedFileURL.path
        return candidate == base || candidate.hasPrefix(base + "/")
    }
}

/// A local-only extraction/index worker. It never asks a backend for bytes and
/// reports `downloadNeeded` when the canonical copy exists remotely but the
/// local protected content is absent.
public enum VaultIndexWorkState: String, Codable, Sendable {
    case indexed
    case downloadNeeded
    case unavailable
    case cancelled
    case failed
}

public struct VaultIndexWorkResult: Equatable, Sendable {
    public let state: VaultIndexWorkState
    public let objectID: VaultObjectID?
    public let jobID: UUID?
    public let errorCode: String?

    public init(state: VaultIndexWorkState, objectID: VaultObjectID?, jobID: UUID?, errorCode: String? = nil) {
        self.state = state
        self.objectID = objectID
        self.jobID = jobID
        self.errorCode = errorCode
    }
}

public final class VaultIndexWorker: @unchecked Sendable {
    private let repository: VaultRepository
    private let metadataStore: VaultImportedFileMetadataStoring
    private let searchIndex: VaultSearchIndex
    private let extractor: VaultExtractionPipeline
    private let embeddings: VaultEmbeddingGenerating?
    private let owner: String
    private let lock = NSLock()

    public init(repository: VaultRepository,
                metadataStore: VaultImportedFileMetadataStoring,
                searchIndex: VaultSearchIndex,
                extractor: VaultExtractionPipeline? = nil,
                embeddings: VaultEmbeddingGenerating? = nil,
                owner: String = "vault-index-worker") {
        self.repository = repository
        self.metadataStore = metadataStore
        self.searchIndex = searchIndex
        self.extractor = extractor ?? VaultExtractionPipeline(artifactWriter: repository)
        self.embeddings = embeddings
        self.owner = owner
    }

    /// Claims one durable `.index` job. The caller can invoke this from a
    /// bounded BGProcessingTask loop; no plaintext is retained after return.
    public func processNext(now: Date = Date()) async -> VaultIndexWorkResult? {
        if Task.isCancelled { return VaultIndexWorkResult(state: .cancelled, objectID: nil, jobID: nil) }
        // The shared queue also carries upload/download work. Claim and defer
        // those rows until an index row is found; otherwise a worker could
        // accidentally leave a non-index lease running and starve local
        // indexing. Deferral is durable and keeps all network work outside
        // this local-only worker.
        var job: VaultJob?
        do {
            for _ in 0..<64 {
                guard let candidate = try repository.claimNextJob(owner: owner, now: now,
                                                                   kinds: [.index]) else { break }
                job = candidate
                break
            }
        } catch {
            return VaultIndexWorkResult(state: .unavailable, objectID: nil, jobID: nil, errorCode: "claim-failed")
        }
        guard let job, job.kind == .index, let objectID = job.objectID, let leaseToken = job.leaseToken else { return nil }
        do {
            guard let revision = job.revision,
                  let record = try repository.object(objectID), !record.isTombstone,
                  record.revision == revision else {
                try repository.transitionJob(id: job.id, leaseToken: leaseToken, state: .failed,
                                             error: "stale-object", now: now)
                return VaultIndexWorkResult(state: .failed, objectID: objectID, jobID: job.id, errorCode: "stale-object")
            }
            guard let metadata = try metadataStore.metadata(objectID: objectID, revision: revision) else {
                try repository.transitionJob(id: job.id, leaseToken: leaseToken, state: .failed,
                                             error: "missing-metadata", now: now)
                return VaultIndexWorkResult(state: .failed, objectID: objectID, jobID: job.id, errorCode: "missing-metadata")
            }
            let data: Data
            if record.size > extractor.policy.maximumMaterializedInputBytes {
                // The extractor has an explicit metadata-only route for valid
                // objects larger than its in-memory budget. Do not read a
                // multi-gigabyte object just to discover that limit.
                data = Data()
            } else if let local = try repository.readContent(for: objectID) {
                data = local
            } else {
                try repository.transitionJob(id: job.id, leaseToken: leaseToken, state: .retrying,
                                             error: "download-needed", nextAttemptAt: now.addingTimeInterval(60), now: now)
                return VaultIndexWorkResult(state: .downloadNeeded, objectID: objectID, jobID: job.id, errorCode: "download-needed")
            }
            if Task.isCancelled {
                try repository.transitionJob(id: job.id, leaseToken: leaseToken, state: .retrying,
                                             error: "cancelled", nextAttemptAt: now.addingTimeInterval(60), now: now)
                return VaultIndexWorkResult(state: .cancelled, objectID: objectID, jobID: job.id)
            }
            let descriptor = VaultFileDescriptor(objectID: objectID, revision: revision,
                                                 fileName: metadata.fileName, contentType: metadata.contentType,
                                                 byteCount: metadata.byteCount, createdAt: metadata.createdAt,
                                                 updatedAt: metadata.updatedAt)
            let heartbeat = Task { [repository] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                    catch { break }
                    try? repository.heartbeatJob(id: job.id, leaseToken: leaseToken, now: Date(), leaseDuration: 120)
                }
            }
            defer { heartbeat.cancel() }
            let extraction = try await extractor.extract(VaultExtractionRequest(descriptor: descriptor, data: data))
            var body = ""
            var ocr = ""
            var transcript = ""
            for chunk in extraction.chunks {
                switch chunk.provenance {
                case .ocr: ocr += (ocr.isEmpty ? "" : "\n") + chunk.text
                case .speech: transcript += (transcript.isEmpty ? "" : "\n") + chunk.text
                default: body += (body.isEmpty ? "" : "\n") + chunk.text
                }
            }
            let embedding = try await makeEmbedding(body: body, ocr: ocr, transcript: transcript)
            let indexed = VaultIndexedDocument(id: objectID, revision: revision,
                                               logicalTime: record.logicalTime, deviceID: record.deviceID,
                                               filename: metadata.fileName, bodyText: body,
                                               ocrText: ocr, transcriptText: transcript,
                                               createdAt: metadata.createdAt, updatedAt: metadata.updatedAt,
                                               accessedAt: Date(), source: .device, embedding: embedding)
            _ = try searchIndex.upsert(indexed)
            try repository.transitionJob(id: job.id, leaseToken: leaseToken, state: .succeeded, now: Date())
            return VaultIndexWorkResult(state: .indexed, objectID: objectID, jobID: job.id)
        } catch is CancellationError {
            try? repository.transitionJob(id: job.id, leaseToken: leaseToken, state: .retrying,
                                          error: "cancelled", nextAttemptAt: Date().addingTimeInterval(60), now: Date())
            return VaultIndexWorkResult(state: .cancelled, objectID: objectID, jobID: job.id)
        } catch {
            try? repository.transitionJob(id: job.id, leaseToken: leaseToken, state: .failed,
                                          error: Self.redactedCode(error), now: Date())
            return VaultIndexWorkResult(state: .failed, objectID: objectID, jobID: job.id,
                                        errorCode: Self.redactedCode(error))
        }
    }

    private func makeEmbedding(body: String, ocr: String, transcript: String) async throws -> VaultEmbedding? {
        guard let embeddings else { return nil }
        let text = [body, ocr, transcript].filter { !$0.isEmpty }.joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        return try await embeddings.embedding(for: text).validated()
    }

    private static func redactedCode(_ error: Error) -> String {
        if let extraction = error as? VaultExtractionError {
            switch extraction {
            case .cancelled: return "cancelled"
            case .timedOut: return "timed-out"
            case .modelUnavailable: return "model-unavailable"
            default: return "extraction-failed"
            }
        }
        if error is VaultEmbeddingError { return "embedding-failed" }
        return "index-failed"
    }
}

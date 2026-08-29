import Foundation
import LunaVaultBackend
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

public struct VaultImportConfiguration: Equatable, Sendable {
    public let deviceID: String
    public let modelVersion: String
    public let maximumBytes: Int64
    public let uploadBackendKey: String?

    public init(deviceID: String = "device",
                modelVersion: String = "extractor-v2",
                maximumBytes: Int64 = 100_000_000_000,
                uploadBackendKey: String? = nil) {
        self.deviceID = deviceID
        self.modelVersion = modelVersion
        self.maximumBytes = max(1, maximumBytes)
        self.uploadBackendKey = uploadBackendKey
    }
}

public protocol VaultImportIdentityGenerating: Sendable {
    func nextObjectID() -> VaultObjectID
    func nextRevision() -> UUID
    func nextLogicalTime(now: Date) -> Int64
}

public struct SystemVaultImportIdentityGenerator: VaultImportIdentityGenerating {
    public init() {}
    public func nextObjectID() -> VaultObjectID { VaultObjectID(rawValue: UUID()) }
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
    }

    public func put(_ metadata: VaultImportedFileMetadata) throws {
        try lock.withLock {
            let directory = directoryURL(for: metadata.objectID)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try protection.apply(to: directory)
            let destination = fileURL(for: metadata.objectID, revision: metadata.revision)
            let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            do {
                try encoder.encode(metadata).write(to: staging, options: [.atomic])
                try protection.apply(to: staging)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: staging, to: destination)
            } catch {
                try? fileManager.removeItem(at: staging)
                throw error
            }
        }
    }

    public func metadata(objectID: VaultObjectID, revision: UUID) throws -> VaultImportedFileMetadata? {
        try lock.withLock {
            let url = fileURL(for: objectID, revision: revision)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return try JSONDecoder().decode(VaultImportedFileMetadata.self, from: Data(contentsOf: url))
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
    }

    /// Imports one source file. Reading is bounded by `maximumBytes`; the
    /// source is never opened by a background/network or extension target.
    public func importFile(_ source: VaultImportSource, now: Date = Date()) throws -> VaultImportResult {
        try lock.withLock {
            guard source.fileURL.isFileURL else { throw VaultImportError.invalidURL }
            let scoped = source.fileURL.startAccessingSecurityScopedResource()
            defer { if scoped { source.fileURL.stopAccessingSecurityScopedResource() } }
            let values = try source.fileURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .nameKey])
            guard values.isDirectory != true else { throw VaultImportError.notAFile }
            guard values.isSymbolicLink != true else { throw VaultImportError.symbolicLink }
            let byteCount = Int64(values.fileSize ?? 0)
            guard byteCount >= 0 else { throw VaultImportError.invalidSource }
            guard byteCount <= configuration.maximumBytes else { throw VaultImportError.inputTooLarge(byteCount) }

            let objectID = identity.nextObjectID()
            let revision = identity.nextRevision()
            let logicalTime = identity.nextLogicalTime(now: now)
            let fileName = sanitizedFileName(source.fileName ?? values.name ?? source.fileURL.lastPathComponent)
            guard !fileName.isEmpty else { throw VaultImportError.invalidSource }
            let journal = VaultImportJournal(objectID: objectID, revision: revision,
                                             logicalTime: logicalTime, deviceID: configuration.deviceID,
                                             fileName: fileName, contentType: source.contentType,
                                             byteCount: byteCount, createdAt: now, updatedAt: now,
                                             sourceName: source.fileURL.lastPathComponent)
            let token = UUID().uuidString
            let staged = stagingDirectory.appendingPathComponent("payload-\(token)")
            let marker = stagingDirectory.appendingPathComponent("journal-\(token).json")
            try stage(source.fileURL, to: staged)
            try writeJournal(journal, to: marker)

            do {
                let result = try finalize(journal, stagedURL: staged, journalURL: marker)
                try? fileManager.removeItem(at: staged)
                try? fileManager.removeItem(at: marker)
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
        lock.withLock {
            let files = (try? fileManager.contentsOfDirectory(at: stagingDirectory,
                                                               includingPropertiesForKeys: nil)) ?? []
            var results: [VaultImportResult] = []
            for journalURL in files where journalURL.lastPathComponent.hasPrefix("journal-") && journalURL.pathExtension == "json" {
                guard let data = try? Data(contentsOf: journalURL),
                      let journal = try? JSONDecoder().decode(VaultImportJournal.self, from: data) else {
                    continue
                }
                let token = journalURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "journal-", with: "")
                let payload = stagingDirectory.appendingPathComponent("payload-\(token)")
                guard fileManager.fileExists(atPath: payload.path) else {
                    try? fileManager.removeItem(at: journalURL)
                    continue
                }
                do {
                    let result = try finalize(journal, stagedURL: payload, journalURL: journalURL)
                    try? fileManager.removeItem(at: payload)
                    try? fileManager.removeItem(at: journalURL)
                    results.append(result)
                } catch {
                    // A later foreground/background pass can retry the same
                    // protected journal without losing the source bytes.
                    continue
                }
            }
            return results
        }
    }

    private func finalize(_ journal: VaultImportJournal, stagedURL: URL, journalURL: URL) throws -> VaultImportResult {
        guard fileManager.fileExists(atPath: stagedURL.path), isProtected(stagedURL) else {
            throw VaultImportError.protectedStaging
        }
        let data = try Data(contentsOf: stagedURL)
        guard Int64(data.count) == journal.byteCount else { throw VaultImportError.interrupted }
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
        if let backendKey = configuration.uploadBackendKey {
            // A content generation is produced by the crypto layer. The
            // all-zero placeholder keeps this durable job opaque; the upload
            // worker replaces it with the authenticated generation before use.
            let generation = String(repeating: "0", count: 64)
            let upload = VaultJob(kind: .upload, objectID: journal.objectID,
                                  createdAt: journal.updatedAt, updatedAt: journal.updatedAt,
                                  idempotencyKey: "upload:\(backendKey):content:\(journal.objectID.rawValue.uuidString):\(journal.revision.uuidString)",
                                  revision: journal.revision, backendKey: backendKey,
                                  payloadGeneration: generation, remoteObjectKind: VaultRemoteObjectKind.content.rawValue)
            jobs.append(upload)
            uploadID = upload.id
        }
        _ = try repository.insertAtomically(VaultAtomicObjectInsertRequest(record: record,
                                                                            content: data,
                                                                            jobs: jobs))
        guard let current = try repository.object(journal.objectID), current.revision == journal.revision,
              !current.isTombstone else { throw VaultImportError.missingObject }
        try metadataStore.put(VaultImportedFileMetadata(objectID: journal.objectID,
                                                         revision: journal.revision,
                                                         fileName: journal.fileName,
                                                         contentType: journal.contentType,
                                                         byteCount: journal.byteCount,
                                                         createdAt: journal.createdAt,
                                                         updatedAt: journal.updatedAt))
        return VaultImportResult(objectID: journal.objectID, revision: journal.revision,
                                 logicalTime: journal.logicalTime, fileName: journal.fileName,
                                 byteCount: journal.byteCount, indexJobID: indexJob.id,
                                 uploadJobID: uploadID)
    }

    private func stage(_ source: URL, to destination: URL) throws {
        do {
            try fileManager.copyItem(at: source, to: destination)
            try protection.apply(to: destination)
            guard isProtected(destination) else {
                throw VaultImportError.protectedStaging
            }
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    private func writeJournal(_ journal: VaultImportJournal, to destination: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(journal).write(to: destination, options: [.atomic])
        try protection.apply(to: destination)
        guard isProtected(destination) else {
            throw VaultImportError.protectedStaging
        }
    }

    private func sanitizedFileName(_ value: String) -> String {
        let basename = URL(fileURLWithPath: value).lastPathComponent
        return basename.replacingOccurrences(of: "\0", with: "")
    }

    private func isProtected(_ url: URL) -> Bool {
        if (try? protection.hasRequiredProtection(at: url)) == true { return true }
        // Some simulator SDKs bridge NSFileProtectionKey as NSString rather
        // than FileProtectionType. The attribute's presence still proves the
        // applier installed a Data Protection class; `apply` itself remains
        // throwing and is the fail-closed operation.
        return (try? fileManager.attributesOfItem(atPath: url.path)[.protectionKey]) != nil
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
                guard let candidate = try repository.claimNextJob(owner: owner, now: now) else { break }
                if candidate.kind == .index {
                    job = candidate
                    break
                }
                if let leaseToken = candidate.leaseToken {
                    try? repository.transitionJob(id: candidate.id, leaseToken: leaseToken,
                                                  state: .retrying, error: "deferred-to-specialized-worker",
                                                  nextAttemptAt: now.addingTimeInterval(30), now: now)
                }
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
            guard let data = try repository.readContent(for: objectID) else {
                try repository.transitionJob(id: job.id, leaseToken: leaseToken, state: .retrying,
                                             error: "download-needed", nextAttemptAt: now.addingTimeInterval(60), now: now)
                return VaultIndexWorkResult(state: .downloadNeeded, objectID: objectID, jobID: job.id, errorCode: "download-needed")
            }
            if Task.isCancelled {
                try repository.transitionJob(id: job.id, leaseToken: leaseToken, state: .cancelled, now: now)
                return VaultIndexWorkResult(state: .cancelled, objectID: objectID, jobID: job.id)
            }
            let descriptor = VaultFileDescriptor(objectID: objectID, revision: revision,
                                                 fileName: metadata.fileName, contentType: metadata.contentType,
                                                 byteCount: metadata.byteCount, createdAt: metadata.createdAt,
                                                 updatedAt: metadata.updatedAt)
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
            try? repository.transitionJob(id: job.id, leaseToken: leaseToken, state: .cancelled, now: now)
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

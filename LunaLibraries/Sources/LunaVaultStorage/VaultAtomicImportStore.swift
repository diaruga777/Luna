import Foundation
import LunaVaultCrypto
import LunaVaultModels

/// The setup layer uses this request to keep object installation and its
/// durable follow-up operations together at one storage boundary. Jobs are
/// idempotent, so a caller may safely retry a request after process death.
public struct VaultAtomicObjectInsertRequest: Sendable {
    public let record: VaultObjectRecord
    public let content: Data
    /// A protected staging file can be installed without materialising the
    /// object's bytes in memory. Exactly one of `content` or `contentURL`
    /// carries the source; the Data initializer remains source-compatible for
    /// small callers and tests.
    public let contentURL: URL?
    public let contentByteCount: Int64
    public let jobs: [VaultJob]
    /// Keep the object invisible until a caller has committed sidecar
    /// metadata and all durable jobs.
    public let deferVisibility: Bool
    public var authenticatedGeneration: VaultAuthenticatedGeneration?

    public init(record: VaultObjectRecord, content: Data, jobs: [VaultJob] = [],
                deferVisibility: Bool = false) {
        self.record = record
        self.content = content
        self.contentURL = nil
        self.contentByteCount = Int64(content.count)
        self.jobs = jobs
        self.deferVisibility = deferVisibility
        self.authenticatedGeneration = nil
    }

    public init(record: VaultObjectRecord, contentURL: URL, contentByteCount: Int64,
                jobs: [VaultJob] = [], deferVisibility: Bool = false) {
        self.record = record
        self.content = Data()
        self.contentURL = contentURL
        self.contentByteCount = contentByteCount
        self.jobs = jobs
        self.deferVisibility = deferVisibility
        self.authenticatedGeneration = nil
    }

    public init(record: VaultObjectRecord, contentURL: URL, contentByteCount: Int64,
                authenticatedGeneration: VaultAuthenticatedGeneration?,
                jobs: [VaultJob] = [], deferVisibility: Bool = false) {
        self.init(record: record, contentURL: contentURL, contentByteCount: contentByteCount,
                  jobs: jobs, deferVisibility: deferVisibility)
        self.authenticatedGeneration = authenticatedGeneration
    }
}

public protocol VaultAtomicObjectInserting: Sendable {
    @discardableResult
    func insertAtomically(_ request: VaultAtomicObjectInsertRequest) throws -> Bool
}

extension VaultRepository: VaultAtomicObjectInserting {
    @discardableResult
    public func insertAtomically(_ request: VaultAtomicObjectInsertRequest) throws -> Bool {
        guard request.record.size >= 0,
              request.contentByteCount == request.record.size else {
            throw VaultStorageError.invalidArtifact
        }
        if let current = try object(request.record.id) {
            guard !current.isTombstone,
                  current.revision == request.record.revision else { return false }
            // A replay after a crash can find the object already installed.
            // Continue with the content/job repair instead of creating a new
            // revision or duplicating durable work.
        } else if try !upsert(request.record) {
            return false
        }
        do {
            if request.deferVisibility { try setObjectReady(request.record.id, ready: false) }
            if try localContentCapability(for: request.record.id) == nil {
                if let contentURL = request.contentURL {
                    _ = try writeContent(from: contentURL,
                                         expectedByteCount: request.contentByteCount,
                                         for: request.record.id,
                                         visibility: !request.deferVisibility,
                                         authenticatedGeneration: request.authenticatedGeneration)
                } else {
                    _ = try writeContent(request.content, for: request.record.id,
                                         visibility: !request.deferVisibility,
                                         authenticatedGeneration: request.authenticatedGeneration)
                }
            }
            for job in request.jobs { try enqueue(job) }
            // A deferred request intentionally remains invisible. The caller
            // publishes it after its sidecar metadata transaction commits.
            return true
        } catch {
            // Keep the object row as a durable recovery anchor. The import
            // journal can retry the missing content/jobs on the next launch;
            // never silently claim an incomplete import succeeded.
            throw error
        }
    }

    /// Descriptor-preserving import boundary.  The setup coordinator keeps
    /// the protected staging inode open from its initial hash through this
    /// call; the repository must not reopen a mutable pathname after that
    /// hash and accidentally install different bytes.
    @discardableResult
    public func insertAtomically(_ request: VaultAtomicObjectInsertRequest,
                                 contentHandle: FileHandle) throws -> Bool {
        guard request.contentURL != nil || request.content.isEmpty,
              request.record.size >= 0,
              request.contentByteCount == request.record.size else {
            throw VaultStorageError.invalidArtifact
        }
        if let current = try object(request.record.id) {
            guard !current.isTombstone, current.revision == request.record.revision else { return false }
        } else if try !upsert(request.record) {
            return false
        }
        do {
            if request.deferVisibility { try setObjectReady(request.record.id, ready: false) }
            if try localContentCapability(for: request.record.id) == nil {
                try writeContent(from: contentHandle,
                                 expectedByteCount: request.contentByteCount,
                                 for: request.record.id,
                                 visibility: !request.deferVisibility,
                                 authenticatedGeneration: request.authenticatedGeneration)
            }
            for job in request.jobs { try enqueue(job) }
            return true
        } catch {
            throw error
        }
    }
}

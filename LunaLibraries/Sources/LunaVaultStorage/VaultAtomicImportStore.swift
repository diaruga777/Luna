import Foundation
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

    public init(record: VaultObjectRecord, content: Data, jobs: [VaultJob] = [],
                deferVisibility: Bool = false) {
        self.record = record
        self.content = content
        self.contentURL = nil
        self.contentByteCount = Int64(content.count)
        self.jobs = jobs
        self.deferVisibility = deferVisibility
    }

    public init(record: VaultObjectRecord, contentURL: URL, contentByteCount: Int64,
                jobs: [VaultJob] = [], deferVisibility: Bool = false) {
        self.record = record
        self.content = Data()
        self.contentURL = contentURL
        self.contentByteCount = contentByteCount
        self.jobs = jobs
        self.deferVisibility = deferVisibility
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
                                         visibility: !request.deferVisibility)
                } else {
                    _ = try writeContent(request.content, for: request.record.id,
                                         visibility: !request.deferVisibility)
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
}

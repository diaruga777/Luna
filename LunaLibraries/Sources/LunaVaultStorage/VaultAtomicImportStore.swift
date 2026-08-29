import Foundation
import LunaVaultModels

/// The setup layer uses this request to keep object installation and its
/// durable follow-up operations together at one storage boundary. Jobs are
/// idempotent, so a caller may safely retry a request after process death.
public struct VaultAtomicObjectInsertRequest: Sendable {
    public let record: VaultObjectRecord
    public let content: Data
    public let jobs: [VaultJob]

    public init(record: VaultObjectRecord, content: Data, jobs: [VaultJob] = []) {
        self.record = record
        self.content = content
        self.jobs = jobs
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
              Int64(request.content.count) == request.record.size else {
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
            if try readContent(for: request.record.id) == nil {
                _ = try writeContent(request.content, for: request.record.id)
            }
            for job in request.jobs { try enqueue(job) }
            return true
        } catch {
            // Keep the object row as a durable recovery anchor. The import
            // journal can retry the missing content/jobs on the next launch;
            // never silently claim an incomplete import succeeded.
            throw error
        }
    }
}

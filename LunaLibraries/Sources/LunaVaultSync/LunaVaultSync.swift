import Foundation
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultModels
import LunaVaultStorage

public enum LunaVaultSyncModule {
    public static let identifier = "LunaVaultSync"
}

public struct VaultSyncConfiguration: Equatable, Sendable {
    public let allowsCellularAccess: Bool
    public let location: VaultStorageLocation

    public init(
        allowsCellularAccess: Bool = true,
        location: VaultStorageLocation = .device
    ) {
        self.allowsCellularAccess = allowsCellularAccess
        self.location = location
    }
}

public enum VaultSyncError: Error, Equatable, Sendable {
    case missingPayload
    case jobAlreadyClaimed
    case backend(VaultBackendError)
}

/// The encrypted payload source is intentionally separate from the backend.
/// Its implementation must persist ciphertext (including manifests/index
/// artifacts) before enqueueing a job, so a process crash can replay a job
/// without retaining plaintext in the durable job row.
public protocol VaultSyncPayloadSource: Sendable {
    func uploadPayload(for id: VaultObjectID) async throws -> Data?
    func saveDownloadedPayload(_ payload: Data, for id: VaultObjectID) async throws
}

public struct VaultSyncOperationResult: Equatable, Sendable {
    public let objectID: VaultObjectID
    public let attempts: Int
    public let state: VaultJobState

    public init(objectID: VaultObjectID, attempts: Int, state: VaultJobState) {
        self.objectID = objectID
        self.attempts = attempts
        self.state = state
    }
}

/// Durable, idempotent upload/download orchestration shared by iCloud and the
/// eventual Mac transport. Jobs are written before the backend call and are
/// completed only after the backend returns. Replaying after a crash is safe:
/// object-ID writes replace the same opaque object and the source owns the
/// encrypted staging bytes.
public final class VaultSyncCoordinator: @unchecked Sendable {
    private let repository: VaultRepository
    private let backend: VaultBackendTransport
    private let payloadSource: VaultSyncPayloadSource
    private let owner: String
    private let lock = NSLock()

    public init(repository: VaultRepository,
                backend: VaultBackendTransport,
                payloadSource: VaultSyncPayloadSource,
                owner: String) {
        self.repository = repository
        self.backend = backend
        self.payloadSource = payloadSource
        self.owner = owner
    }

    public func upload(_ id: VaultObjectID, now: Date = Date()) async throws -> VaultSyncOperationResult {
        let job = VaultJob(kind: .upload, objectID: id,
                           createdAt: now, updatedAt: now,
                           idempotencyKey: "upload:\(id.rawValue.uuidString)")
        try enqueueIfNeeded(job)
        guard let queued = try repository.job(idempotencyKey: job.idempotencyKey) else {
            throw VaultSyncError.jobAlreadyClaimed
        }
        if queued.state == .succeeded {
            return VaultSyncOperationResult(objectID: id, attempts: queued.attempts, state: .succeeded)
        }
        guard let claimed = try repository.claimJob(id: queued.id, owner: owner, now: now) else {
            throw VaultSyncError.jobAlreadyClaimed
        }
        do {
            guard let payload = try await payloadSource.uploadPayload(for: id) else {
                throw VaultSyncError.missingPayload
            }
            try await backend.retrying { [backend] in
                try await backend.putCiphertext(payload, for: id)
            }
            try repository.transitionJob(id: claimed.id, owner: owner, state: .succeeded, now: now)
            return VaultSyncOperationResult(objectID: id, attempts: claimed.attempts, state: .succeeded)
        } catch {
            let syncError = Self.map(error)
            try? repository.transitionJob(id: claimed.id, owner: owner, state: .retrying,
                                          error: String(describing: syncError),
                                          nextAttemptAt: now.addingTimeInterval(30), now: now)
            throw syncError
        }
    }

    public func download(_ id: VaultObjectID, now: Date = Date()) async throws -> VaultSyncOperationResult {
        let job = VaultJob(kind: .download, objectID: id,
                           createdAt: now, updatedAt: now,
                           idempotencyKey: "download:\(id.rawValue.uuidString)")
        try enqueueIfNeeded(job)
        guard let queued = try repository.job(idempotencyKey: job.idempotencyKey) else {
            throw VaultSyncError.jobAlreadyClaimed
        }
        if queued.state == .succeeded {
            return VaultSyncOperationResult(objectID: id, attempts: queued.attempts, state: .succeeded)
        }
        guard let claimed = try repository.claimJob(id: queued.id, owner: owner, now: now) else {
            throw VaultSyncError.jobAlreadyClaimed
        }
        do {
            guard let payload = try await backend.retrying(operation: { [backend] in
                try await backend.ciphertext(for: id)
            }) else { throw VaultSyncError.missingPayload }
            try await payloadSource.saveDownloadedPayload(payload, for: id)
            try repository.transitionJob(id: claimed.id, owner: owner, state: .succeeded, now: now)
            return VaultSyncOperationResult(objectID: id, attempts: claimed.attempts, state: .succeeded)
        } catch {
            let syncError = Self.map(error)
            try? repository.transitionJob(id: claimed.id, owner: owner, state: .retrying,
                                          error: String(describing: syncError),
                                          nextAttemptAt: now.addingTimeInterval(30), now: now)
            throw syncError
        }
    }

    private func enqueueIfNeeded(_ job: VaultJob) throws {
        // SQLite's UNIQUE idempotency key makes concurrent callers collapse to
        // one durable operation. The lock only keeps claim ordering clear for
        // callers sharing this coordinator instance.
        lock.lock(); defer { lock.unlock() }
        try repository.enqueue(job)
    }

    private static func map(_ error: Error) -> VaultSyncError {
        if let error = error as? VaultSyncError { return error }
        if let error = error as? VaultBackendError { return .backend(error) }
        return .backend(.io(String(describing: error)))
    }
}

import Foundation
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultModels
import LunaVaultStorage

public enum LunaVaultSyncModule { public static let identifier = "LunaVaultSync" }

public struct VaultSyncConfiguration: Equatable, Sendable {
    public let allowsCellularAccess: Bool
    public let location: VaultStorageLocation
    public let maximumAttempts: Int
    public let initialBackoff: TimeInterval
    public let maximumBackoff: TimeInterval

    public init(allowsCellularAccess: Bool = true,
                location: VaultStorageLocation = .device,
                maximumAttempts: Int = 6,
                initialBackoff: TimeInterval = 5,
                maximumBackoff: TimeInterval = 3600) {
        self.allowsCellularAccess = allowsCellularAccess
        self.location = location
        self.maximumAttempts = max(1, maximumAttempts)
        self.initialBackoff = max(0, initialBackoff)
        self.maximumBackoff = max(initialBackoff, maximumBackoff)
    }
}

public enum VaultSyncWakeReason: String, Codable, Sendable {
    case scheduled, providerStateChanged, userRequested
}

public enum VaultSyncFailureCode: String, Codable, Error, Equatable, Sendable {
    case missingPayload = "missing_payload"
    case alreadyClaimed = "already_claimed"
    case uploadPending = "upload_pending"
    case retryExhausted = "retry_exhausted"
    case invalidArtifact = "invalid_artifact"
}

public enum VaultSyncError: Error, Equatable, Sendable {
    case sync(VaultSyncFailureCode)
    case backend(VaultBackendError)

    public var redactedCode: String {
        switch self {
        case .sync(let code): return code.rawValue
        case .backend(let error): return "backend_\(error.rawValue)"
        }
    }

    public var isTransient: Bool {
        switch self {
        case .backend(let error): return error.isTransient
        case .sync(.uploadPending), .sync(.alreadyClaimed): return true
        case .sync: return false
        }
    }
}

public protocol VaultSyncPayloadSource: Sendable {
    func stageUpload(_ payload: VaultAuthenticatedCiphertext) async throws
    func uploadPayload(for identity: VaultRemoteObjectIdentity) async throws -> VaultVerifiedCiphertext?
    func installDownloadedPayload(_ payload: VaultAuthenticatedCiphertext) async throws
    func removeUploadPayload(for identity: VaultRemoteObjectIdentity) async throws
    func removeAllPayloads(for identity: VaultRemoteObjectIdentity) async throws
}

/// Optional file-backed companion to `VaultSyncPayloadSource`.  A sync
/// coordinator selects these methods whenever both sides support them, so a
/// remote content object is never represented by one whole-object `Data`.
public protocol VaultStreamingSyncPayloadSource: VaultSyncPayloadSource {
    func stageUploadFile(_ payload: VaultAuthenticatedCiphertextFile) async throws
    func uploadPayloadFile(for identity: VaultRemoteObjectIdentity) async throws
        -> VaultVerifiedCiphertextFile?
    func installDownloadedPayloadFile(_ payload: VaultAuthenticatedCiphertextFile) async throws
}

public struct VaultSyncOperationResult: Equatable, Sendable {
    public let identity: VaultRemoteObjectIdentity
    public let attempts: Int
    public let state: VaultJobState
    public init(identity: VaultRemoteObjectIdentity, attempts: Int, state: VaultJobState) {
        self.identity = identity; self.attempts = attempts; self.state = state
    }
}

public final class VaultSyncCoordinator: @unchecked Sendable {
    private let repository: VaultRepository
    private let backend: VaultBackendTransport
    private let payloadSource: VaultSyncPayloadSource
    private let owner: String
    private let configuration: VaultSyncConfiguration
    private let lock = NSLock()

    public init(repository: VaultRepository, backend: VaultBackendTransport,
                payloadSource: VaultSyncPayloadSource, owner: String,
                configuration: VaultSyncConfiguration? = nil) {
        self.repository = repository; self.backend = backend
        self.payloadSource = payloadSource; self.owner = owner
        self.configuration = configuration ?? VaultSyncConfiguration(location: backend.identity.location)
    }

    public func upload(_ payload: VaultAuthenticatedCiphertext,
                       expectedRemoteRevision: UUID? = nil,
                       wakeReason: VaultSyncWakeReason = .scheduled,
                       now: Date = Date()) async throws -> VaultSyncOperationResult {
        guard payload.vaultID == backend.identity.vaultID else {
            throw VaultSyncError.backend(.corruptPayload)
        }
        try await payloadSource.stageUpload(payload)
        let job = makeJob(kind: .upload, identity: payload.identity,
                          expectedRemoteRevision: expectedRemoteRevision, now: now)
        let claimed = try prepareAndClaim(job, wakeReason: wakeReason, now: now)
        if [.succeeded, .failed, .cancelled].contains(claimed.state) { return result(payload.identity, claimed) }
        return try await finishClaim(claimed, identity: payload.identity, now: now) {
            if try await self.backend.state(for: payload.identity) == .current { return .succeeded }
            guard let staged = try await self.payloadSource.uploadPayload(for: payload.identity) else {
                throw VaultSyncError.sync(.missingPayload)
            }
            let outcome = try await self.backend.put(staged, expectedRevision: expectedRemoteRevision)
            if outcome == .current { try await self.payloadSource.removeUploadPayload(for: payload.identity) }
            return outcome == .current ? .succeeded : .retrying
        }
    }

    /// Uploads an already-sealed file-backed envelope. The file identity is
    /// immutable and carries the encrypted-frame generation used by the job.
    public func upload(_ payload: VaultAuthenticatedCiphertextFile,
                       expectedRemoteRevision: UUID? = nil,
                       wakeReason: VaultSyncWakeReason = .scheduled,
                       now: Date = Date()) async throws -> VaultSyncOperationResult {
        guard payload.vaultID == backend.identity.vaultID,
              let source = payloadSource as? VaultStreamingSyncPayloadSource,
              let transport = backend as? VaultStreamingBackendTransport else {
            throw VaultSyncError.sync(.invalidArtifact)
        }
        try await source.stageUploadFile(payload)
        let proposed = makeJob(kind: .upload, identity: payload.identity,
                               expectedRemoteRevision: expectedRemoteRevision, now: now)
        let claimed = try prepareAndClaim(proposed, wakeReason: wakeReason, now: now)
        if [.succeeded, .failed, .cancelled].contains(claimed.state) { return result(payload.identity, claimed) }
        return try await finishClaim(claimed, identity: payload.identity, now: now) {
            if try await self.backend.state(for: payload.identity) == .current {
                try await source.removeUploadPayload(for: payload.identity)
                return .succeeded
            }
            guard let staged = try await source.uploadPayloadFile(for: payload.identity) else {
                throw VaultSyncError.sync(.missingPayload)
            }
            let outcome = try await transport.put(staged, expectedRevision: expectedRemoteRevision)
            if outcome == .current { try await source.removeUploadPayload(for: payload.identity) }
            return outcome == .current ? .succeeded : .retrying
        }
    }

    public func download(_ identity: VaultRemoteObjectIdentity,
                         wakeReason: VaultSyncWakeReason = .scheduled,
                         now: Date = Date()) async throws -> VaultSyncOperationResult {
        let job = makeJob(kind: .download, identity: identity, now: now)
        let claimed = try prepareAndClaim(job, wakeReason: wakeReason, now: now)
        if [.succeeded, .failed, .cancelled].contains(claimed.state) { return result(identity, claimed) }
        return try await finishClaim(claimed, identity: identity, now: now) {
            if let transport = self.backend as? VaultStreamingBackendTransport,
               let source = self.payloadSource as? VaultStreamingSyncPayloadSource {
                guard let payload = try await transport.payloadFile(for: identity) else {
                    throw VaultSyncError.backend(.notFound)
                }
                guard payload.identity == identity else { throw VaultSyncError.backend(.corruptPayload) }
                try await source.installDownloadedPayloadFile(payload)
            } else {
                guard let payload = try await self.backend.payload(for: identity) else {
                    throw VaultSyncError.backend(.notFound)
                }
                guard payload.identity == identity else { throw VaultSyncError.backend(.corruptPayload) }
                try await self.payloadSource.installDownloadedPayload(payload)
            }
            return .succeeded
        }
    }

    public func delete(_ identity: VaultRemoteObjectIdentity,
                       wakeReason: VaultSyncWakeReason = .scheduled,
                       now: Date = Date()) async throws -> VaultSyncOperationResult {
        let job = makeJob(kind: .delete, identity: identity, now: now)
        let claimed = try prepareAndClaim(job, wakeReason: wakeReason, now: now)
        if [.succeeded, .failed, .cancelled].contains(claimed.state) { return result(identity, claimed) }
        return try await finishClaim(claimed, identity: identity, now: now) {
            try await self.backend.remove(identity, expectedRevision: identity.revision)
            guard try await self.backend.state(for: identity) == .missing else {
                throw VaultSyncError.backend(.conflict)
            }
            try await self.payloadSource.removeAllPayloads(for: identity)
            return .succeeded
        }
    }

    public func uploadArtifact(_ artifact: VaultEncryptedArtifact,
                               wakeReason: VaultSyncWakeReason = .scheduled,
                               now: Date = Date()) async throws -> VaultSyncOperationResult {
        let kind: VaultRemoteObjectKind = artifact.kind == .index ? .index : .manifest
        do {
            let payload = try VaultAuthenticatedCiphertext(
                vaultID: artifact.vaultID, kind: kind,
                encryptedFrames: artifact.encryptedFrames)
            return try await upload(payload, wakeReason: wakeReason, now: now)
        } catch let error as VaultSyncError { throw error }
        catch { throw VaultSyncError.sync(.invalidArtifact) }
    }

    /// Replays durable work after a BGTask, app lifecycle, or file-provider
    /// notification. Jobs contain every opaque identity component required to
    /// resume without retaining plaintext or relying on in-memory closures.
    @discardableResult
    public func runReadyJobs(wakeReason: VaultSyncWakeReason,
                             now: Date = Date()) async -> [VaultSyncOperationResult] {
        let candidates = (try? repository.jobs(kinds: [.upload, .download, .delete]))?.filter {
            $0.backendKey == backend.identity.stableKey &&
            [.queued, .retrying, .running].contains($0.state)
        } ?? []
        var results: [VaultSyncOperationResult] = []
        for job in candidates {
            if Task.isCancelled { break }
            guard let identity = remoteIdentity(for: job) else { continue }
            do {
                if wakeReason != .scheduled { try repository.makeJobReady(id: job.id, now: now) }
                guard let claimed = try repository.claimJob(id: job.id, owner: owner, now: now) else { continue }
                let result = try await finishClaim(claimed, identity: identity, now: now) {
                    switch claimed.kind {
                    case .upload:
                        if try await self.backend.state(for: identity) == .current {
                            try await self.payloadSource.removeUploadPayload(for: identity)
                            return .succeeded
                        }
                        let outcome: VaultBackendWriteOutcome
                        if let transport = self.backend as? VaultStreamingBackendTransport,
                           let source = self.payloadSource as? VaultStreamingSyncPayloadSource {
                            guard let payload = try await source.uploadPayloadFile(for: identity) else {
                                throw VaultSyncError.sync(.missingPayload)
                            }
                            outcome = try await transport.put(payload,
                                expectedRevision: claimed.expectedRemoteRevision)
                        } else {
                            guard let payload = try await self.payloadSource.uploadPayload(for: identity) else {
                                throw VaultSyncError.sync(.missingPayload)
                            }
                            outcome = try await self.backend.put(
                                payload, expectedRevision: claimed.expectedRemoteRevision)
                        }
                        if outcome == .current {
                            try await self.payloadSource.removeUploadPayload(for: identity)
                        }
                        return outcome == .current ? .succeeded : .retrying
                    case .download:
                        guard let payload = try await self.backend.payload(for: identity) else {
                            throw VaultSyncError.backend(.notFound)
                        }
                        try await self.payloadSource.installDownloadedPayload(payload)
                        return .succeeded
                    case .delete:
                        try await self.backend.remove(identity, expectedRevision: identity.revision)
                        guard try await self.backend.state(for: identity) == .missing else {
                            throw VaultSyncError.backend(.conflict)
                        }
                        try await self.payloadSource.removeAllPayloads(for: identity)
                        return .succeeded
                    case .importFile, .index:
                        throw VaultSyncError.sync(.invalidArtifact)
                    }
                }
                results.append(result)
            } catch {
                // finishClaim persists a fixed redacted failure code and the
                // next bounded retry time. A later job must still be allowed
                // to run during this wake.
                continue
            }
        }
        return results
    }

    public func hasPendingJobs() -> Bool {
        ((try? repository.jobs(kinds: [.upload, .download, .delete])) ?? []).contains {
            $0.backendKey == backend.identity.stableKey &&
            [.queued, .retrying, .running].contains($0.state)
        }
    }

    private func remoteIdentity(for job: VaultJob) -> VaultRemoteObjectIdentity? {
        guard let objectID = job.objectID, let revision = job.revision,
              let generation = job.payloadGeneration,
              let rawKind = job.remoteObjectKind,
              let kind = VaultRemoteObjectKind(rawValue: rawKind) else { return nil }
        return try? VaultRemoteObjectIdentity(
            objectID: objectID, revision: revision, kind: kind, generation: generation)
    }

    private func makeJob(kind: VaultJobKind, identity: VaultRemoteObjectIdentity,
                         expectedRemoteRevision: UUID? = nil,
                         now: Date) -> VaultJob {
        let key = [kind.rawValue, backend.identity.stableKey,
                   identity.kind.rawValue, identity.objectID.rawValue.uuidString,
                   identity.revision.uuidString, identity.generation].joined(separator: ":")
        return VaultJob(kind: kind, objectID: identity.objectID, createdAt: now, updatedAt: now,
                        idempotencyKey: key, revision: identity.revision,
                        backendKey: backend.identity.stableKey,
                        payloadGeneration: identity.generation,
                        remoteObjectKind: identity.kind.rawValue,
                        expectedRemoteRevision: expectedRemoteRevision)
    }

    private func prepareAndClaim(_ proposed: VaultJob, wakeReason: VaultSyncWakeReason,
                                 now: Date) throws -> VaultJob {
        lock.lock(); defer { lock.unlock() }
        try repository.enqueue(proposed)
        guard let queued = try repository.job(idempotencyKey: proposed.idempotencyKey) else {
            throw VaultSyncError.sync(.alreadyClaimed)
        }
        if [.succeeded, .failed, .cancelled].contains(queued.state) { return queued }
        if wakeReason != .scheduled { try repository.makeJobReady(id: queued.id, now: now) }
        guard let claimed = try repository.claimJob(id: queued.id, owner: owner, now: now),
              claimed.leaseToken != nil else {
            throw VaultSyncError.sync(.alreadyClaimed)
        }
        return claimed
    }

    private func finishClaim(_ claimed: VaultJob, identity: VaultRemoteObjectIdentity,
                             now: Date,
                             operation: () async throws -> VaultJobState) async throws -> VaultSyncOperationResult {
        guard let leaseToken = claimed.leaseToken else { throw VaultSyncError.sync(.alreadyClaimed) }
        if claimed.attempts > configuration.maximumAttempts {
            try repository.transitionJob(id: claimed.id, leaseToken: leaseToken, state: .failed,
                                         error: VaultSyncFailureCode.retryExhausted.rawValue, now: now)
            return VaultSyncOperationResult(identity: identity, attempts: claimed.attempts, state: .failed)
        }
        do {
            let finalState = try await operation()
            if finalState == .retrying {
                if claimed.attempts >= configuration.maximumAttempts {
                    try repository.transitionJob(
                        id: claimed.id, leaseToken: leaseToken, state: .failed,
                        error: VaultSyncFailureCode.retryExhausted.rawValue, now: now)
                    return VaultSyncOperationResult(
                        identity: identity, attempts: claimed.attempts, state: .failed)
                } else {
                    try repository.transitionJob(
                        id: claimed.id, leaseToken: leaseToken, state: .retrying,
                        error: VaultSyncFailureCode.uploadPending.rawValue,
                        nextAttemptAt: now.addingTimeInterval(backoff(claimed.attempts)), now: now)
                }
            } else {
                try repository.transitionJob(id: claimed.id, leaseToken: leaseToken,
                                             state: .succeeded, now: now)
            }
            return VaultSyncOperationResult(identity: identity, attempts: claimed.attempts, state: finalState)
        } catch {
            let syncError = Self.map(error)
            let shouldRetry = syncError.isTransient && claimed.attempts < configuration.maximumAttempts
            try repository.transitionJob(
                id: claimed.id, leaseToken: leaseToken,
                state: shouldRetry ? .retrying : .failed,
                error: syncError.redactedCode,
                nextAttemptAt: shouldRetry ? now.addingTimeInterval(backoff(claimed.attempts)) : nil,
                now: now)
            throw syncError
        }
    }

    private func backoff(_ attempts: Int) -> TimeInterval {
        let exponent = min(max(0, attempts - 1), 20)
        return min(configuration.maximumBackoff,
                   configuration.initialBackoff * pow(2, Double(exponent)))
    }

    private func result(_ identity: VaultRemoteObjectIdentity, _ job: VaultJob) -> VaultSyncOperationResult {
        VaultSyncOperationResult(identity: identity, attempts: job.attempts, state: job.state)
    }

    private static func map(_ error: Error) -> VaultSyncError {
        if let error = error as? VaultSyncError { return error }
        if let error = error as? VaultBackendError { return .backend(error) }
        return .backend(.io)
    }
}

import CryptoKit
import Foundation
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultModels
#if canImport(Darwin)
import Darwin
#endif

public enum LunaVaultMacModule { public static let identifier = "LunaVaultMac" }

public enum VaultMacCompanionError: Error, Equatable, Sendable {
    case invalidRevision, conflict, incompleteUpload, invalidRange
    case diskFailure, quotaExceeded, symlinkRejected, manifestTooLarge, tooManyPartials
    case recoveryCancelled
}

public struct VaultMacCompanionLimits: Equatable, Sendable {
    public static let maximumConfigurableStoredBytes: UInt64 = 16 * 1_099_511_627_776
    public let maximumObjectBytes: UInt64
    public let maximumStoredBytes: UInt64
    public let maximumManifestBytes: Int
    public let maximumPartialUploads: Int
    public let partialUploadLifetime: TimeInterval
    /// Caps the number of object/revision/file entries inspected during the
    /// startup orphan sweep. A malformed or attacker-controlled directory
    /// must not turn companion startup into an unbounded directory walk.
    public let maximumRecoveryEntries: Int
    public init(maximumObjectBytes: UInt64 = VaultMacProtocol.maximumObjectBytes,
                maximumStoredBytes: UInt64 = 1_099_511_627_776,
                maximumManifestBytes: Int = 16 * 1024 * 1024,
                maximumPartialUploads: Int = 64,
                partialUploadLifetime: TimeInterval = 7 * 24 * 60 * 60,
                maximumRecoveryEntries: Int = 4_096) {
        self.maximumObjectBytes = max(1, min(maximumObjectBytes, VaultMacProtocol.maximumObjectBytes))
        self.maximumStoredBytes = min(max(1, maximumStoredBytes), Self.maximumConfigurableStoredBytes)
        self.maximumManifestBytes = max(1, min(maximumManifestBytes, 16 * 1024 * 1024))
        self.maximumPartialUploads = max(1, min(maximumPartialUploads, 1_024))
        self.partialUploadLifetime = partialUploadLifetime.isFinite
            ? max(1, min(partialUploadLifetime, 30 * 24 * 60 * 60))
            : 7 * 24 * 60 * 60
        self.maximumRecoveryEntries = max(1, min(maximumRecoveryEntries, 65_536))
    }
}

public struct VaultMacPairedCredentialStore: Sendable {
    public init() {}
    public func save(_ credential: VaultMacPairingCredential, at url: URL) throws {
        try VaultSecureFileSystem.ensureDirectory(url.deletingLastPathComponent())
        try VaultSecureFileSystem.atomicWrite(try JSONEncoder().encode(credential), to: url, maximumBytes: 16 * 1024)
    }
    public func load(from url: URL) throws -> VaultMacPairingCredential {
        try JSONDecoder().decode(VaultMacPairingCredential.self,
            from: VaultSecureFileSystem.read(url, maximumBytes: 16 * 1024))
    }
    public func revoke(at url: URL, now: Date = Date()) throws {
        let credential = try load(from: url)
        try save(try credential.revoked(now: now), at: url)
    }
}

/// Owns a one-time setup offer. Enrollment succeeds once, only before expiry,
/// and only after the UI confirms the displayed server fingerprint.
public final class VaultMacPairingCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: (offer: VaultMacPairingOffer, code: VaultMacPairingSecret)?
    private var consumed = false
    public init() {}
    public func createOffer(endpointBinding: String, serverBinding: Data,
                            random: VaultRandomBytesGenerating = SystemVaultRandomBytes(),
                            now: Date = Date(), lifetime: TimeInterval = 5 * 60) throws
        -> (VaultMacPairingOffer, VaultMacPairingSecret) {
        try lock.withLock {
            guard !consumed else { throw VaultMacProtocolError.pairingAlreadyConsumed }
            guard lifetime.isFinite, lifetime > 0, lifetime <= 15 * 60 else {
                throw VaultMacProtocolError.invalidChallenge
            }
            let code = try VaultMacPairingSecret(rawValue: random.bytes(count: 32))
            let offer = try VaultMacPairingOffer(pairingID: UUID(), serverBinding: serverBinding,
                endpointBinding: endpointBinding, nonce: random.bytes(count: 32),
                expiresAt: now.addingTimeInterval(lifetime))
            pending = (offer, code); return (offer, code)
        }
    }
    public func enroll(_ enrollment: VaultMacPairingEnrollment,
                       confirmedFingerprint: Bool, now: Date = Date()) throws -> VaultMacPairingCredential {
        try lock.withLock {
            guard confirmedFingerprint else { throw VaultMacProtocolError.unconfirmedServerIdentity }
            guard !consumed, let pending else { throw VaultMacProtocolError.pairingAlreadyConsumed }
            guard now < pending.offer.expiresAt else { throw VaultMacProtocolError.expired }
            guard enrollment.pairingID == pending.offer.pairingID else { throw VaultMacProtocolError.authenticationFailed }
            let expected = try VaultMacPairingEnrollment.make(offer: pending.offer,
                oneTimeCode: pending.code, clientNonce: enrollment.clientNonce, now: now)
            guard constantTimeEqual(expected.proof, enrollment.proof) else { throw VaultMacProtocolError.authenticationFailed }
            let credential = try VaultMacPairingCredential.derive(offer: pending.offer,
                oneTimeCode: pending.code, clientNonce: enrollment.clientNonce, now: now)
            self.pending = nil; consumed = true; return credential
        }
    }
}

/// Issues fresh, short-lived challenges and consumes each session exactly once.
/// A new TCP connection therefore cannot reset the replay window for an old
/// session transcript.
public final class VaultMacSessionAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var credential: VaultMacPairingCredential
    private var pending: [UUID: VaultMacSessionChallenge] = [:]
    private var consumed: Set<UUID> = []
    private let random: VaultRandomBytesGenerating
    public init(credential: VaultMacPairingCredential,
                random: VaultRandomBytesGenerating = SystemVaultRandomBytes()) {
        self.credential = credential; self.random = random
    }
    public func issue(now: Date = Date(), lifetime: TimeInterval = 10) throws -> VaultMacSessionChallenge {
        try lock.withLock {
            guard credential.revokedAt == nil else { throw VaultMacProtocolError.revoked }
            guard lifetime.isFinite, lifetime > 0, lifetime <= 5 * 60 else {
                throw VaultMacProtocolError.invalidChallenge
            }
            pending = pending.filter { $0.value.expiresAt > now }
            guard pending.count < 128 else { throw VaultMacProtocolError.unavailable }
            var sessionID = UUID()
            while pending[sessionID] != nil || consumed.contains(sessionID) { sessionID = UUID() }
            let challenge = try VaultMacSessionChallenge(pairingID: credential.pairingID,
                credentialEpoch: credential.epoch, sessionID: sessionID,
                serverNonce: random.bytes(count: 32), serverBinding: credential.serverBinding,
                endpointBinding: credential.endpointBinding, expiresAt: now.addingTimeInterval(lifetime))
            pending[sessionID] = challenge; return challenge
        }
    }
    public func accept(_ response: VaultMacSessionResponse, now: Date = Date()) throws
        -> (VaultMacSessionChallenge, VaultMacSessionKeys, VaultMacSessionAcceptance) {
        try lock.withLock {
            guard !consumed.contains(response.sessionID),
                  let challenge = pending[response.sessionID] else {
                throw VaultMacProtocolError.replayedFrame
            }
            // Do not remove the challenge until the proof has verified.  The
            // handshake is unauthenticated up to this point; consuming it on
            // a bad response would let any peer burn a legitimate pairing
            // attempt and create a trivial denial of service.
            let keys = try VaultMacSessionKeys(challenge: challenge, response: response,
                                               credential: credential, now: now)
            pending.removeValue(forKey: response.sessionID)
            consumed.insert(response.sessionID)
            if consumed.count > 4_096 { consumed.removeAll(keepingCapacity: true) }
            let acceptance = try VaultMacSessionAcceptance.make(challenge: challenge,
                response: response, credential: credential, now: now)
            return (challenge, keys, acceptance)
        }
    }
    public func rotate(to replacement: VaultMacPairingCredential) throws {
        try lock.withLock {
            guard replacement.revokedAt == nil,
                  replacement.pairingID == credential.pairingID,
                  replacement.epoch > credential.epoch else {
                throw VaultMacProtocolError.invalidSecret
            }
            credential = replacement; pending.removeAll(); consumed.removeAll()
        }
    }
    /// Active listeners call this before every application frame so a revoke
    /// or rotation takes effect without waiting for an existing TCP connection
    /// to go idle.
    public func isCredentialUsable(epoch: UInt64) -> Bool {
        lock.withLock { credential.revokedAt == nil && credential.epoch == epoch }
    }
    public func revoke(now: Date = Date()) throws {
        try lock.withLock { credential = try credential.revoked(now: now); pending.removeAll(); consumed.removeAll() }
    }
}

private struct StoredObject: Codable, Sendable {
    var revision: VaultRevision; var totalBytes: UInt64; var totalChunks: UInt32; var deleted: Bool
    var objectKind: VaultRemoteObjectKind? = nil; var payloadGeneration: String? = nil
    init(revision: VaultRevision, totalBytes: UInt64, totalChunks: UInt32, deleted: Bool,
         objectKind: VaultRemoteObjectKind? = nil, payloadGeneration: String? = nil) {
        self.revision = revision; self.totalBytes = totalBytes; self.totalChunks = totalChunks
        self.deleted = deleted; self.objectKind = objectKind; self.payloadGeneration = payloadGeneration
    }
    private enum CodingKeys: String, CodingKey { case revision, totalBytes, totalChunks, deleted, objectKind, payloadGeneration }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try c.decode(VaultRevision.self, forKey: .revision)
        totalBytes = try c.decode(UInt64.self, forKey: .totalBytes)
        totalChunks = try c.decode(UInt32.self, forKey: .totalChunks)
        deleted = try c.decode(Bool.self, forKey: .deleted)
        objectKind = try c.decodeIfPresent(VaultRemoteObjectKind.self, forKey: .objectKind)
        payloadGeneration = try c.decodeIfPresent(String.self, forKey: .payloadGeneration)
    }
}
private struct PartialUpload: Codable, Sendable {
    var revision: VaultRevision; var totalBytes: UInt64; var totalChunks: UInt32
    // A Set, not an array: putChunk's `contains` + insert must be O(1)
    // amortized rather than the O(n) contains + O(n log n) sort per chunk an
    // array demanded, which made accepting an n-chunk upload O(n^2).
    var receivedChunks: Set<UInt32>; var receivedBytes: UInt64; var updatedAt: Date
    var objectKind: VaultRemoteObjectKind? = nil; var payloadGeneration: String? = nil
}
private struct IdempotencyRecord: Codable, Sendable {
    var signature: Data; var response: VaultMacResponse; var createdAt: Date
}
private struct CompanionManifest: Codable, Sendable {
    var objects: [String: StoredObject] = [:]
    var partialUploads: [String: PartialUpload] = [:]
    var idempotency: [String: IdempotencyRecord] = [:]
}
private struct ManifestEnvelope: Codable { let nonce: Data; let ciphertext: Data; let tag: Data }

/// A single budget is shared by recovery enumeration and every recursive
/// orphan deletion it triggers.  Counting only `readdir` results is unsafe:
/// an unrecognised directory could otherwise contain an unlimited subtree and
/// make companion startup spend unbounded time deleting it.
private struct VaultMacRecoveryBudget {
    private(set) var remaining: Int

    init(maximumEntries: Int) { remaining = max(1, maximumEntries) }

    mutating func inspectEntry() throws {
        guard !Task.isCancelled else { throw VaultMacCompanionError.recoveryCancelled }
        guard remaining > 0 else { throw VaultMacCompanionError.tooManyPartials }
        remaining -= 1
    }
}

public actor VaultMacCompanionStore {
    public let rootURL: URL
    private var credential: VaultMacPairingCredential
    private let limits: VaultMacCompanionLimits
    private var manifest: CompanionManifest

    public init(rootURL: URL, credential: VaultMacPairingCredential,
                limits: VaultMacCompanionLimits = VaultMacCompanionLimits(), now: Date = Date()) throws {
        guard credential.revokedAt == nil else { throw VaultMacProtocolError.revoked }
        self.rootURL = rootURL; self.credential = credential; self.limits = limits
        try VaultSecureFileSystem.ensureDirectory(rootURL)
        try VaultSecureFileSystem.ensureDirectory(rootURL.appendingPathComponent("objects", isDirectory: true))
        self.manifest = try Self.loadManifest(rootURL: rootURL, credential: credential, limits: limits)
        try Self.recover(rootURL: rootURL, manifest: &self.manifest, limits: limits, now: now)
        try Self.writeManifest(manifest, rootURL: rootURL, credential: credential, limits: limits)
    }

    public func handle(_ rawRequest: VaultMacRequest, now: Date = Date()) throws -> VaultMacResponse {
        let request = try rawRequest.validated()
        let signatureEncoder = JSONEncoder()
        signatureEncoder.outputFormatting = [.sortedKeys]
        let signature = SHA256.hash(data: try signatureEncoder.encode(request)).withUnsafeBytes { Data($0) }
        if let existing = manifest.idempotency[request.idempotencyKey] {
            guard constantTimeEqual(existing.signature, signature) else { throw VaultMacCompanionError.conflict }
            if request.operation == .putChunk { return replayedPutChunkResponse(existing.response, for: request) }
            try cleanupCommittedState(for: request.objectID)
            return existing.response
        }
        // `stat` and `readRange` have no side effect to make idempotent and
        // are deterministic over the current object state, so recomputing
        // them on every call is already correct. Returning here before any
        // manifest write is what keeps a 100 GiB download's ~25,600
        // readRange calls from each re-encrypting and fsyncing the whole
        // manifest.
        switch request.operation {
        case .stat: return stat(request)
        case .readRange: return try readRange(request)
        case .putChunk:
            let (response, committedStateChanged) = try putChunk(request, now: now)
            try finalizeMutation(response, request: request, signature: signature, now: now,
                                 committedStateChanged: committedStateChanged,
                                 storedResponse: putChunkStorageResponse(response))
            return response
        case .delete:
            let (response, committedStateChanged) = try delete(request)
            try finalizeMutation(response, request: request, signature: signature, now: now,
                                 committedStateChanged: committedStateChanged, storedResponse: response)
            return response
        }
    }

    /// Only a durable partial or a committed upload is worth remembering.
    /// Memoizing a `.conflict`/`.notFound`/`.invalid` response would freeze
    /// this idempotency key against a legitimate retry for the rest of its
    /// 30-day retention — the poisoning the client-side revision cache exists
    /// to route around. `cleanupCommittedState` and the chunk-file sweep only
    /// run when this request actually changed which revision is retained.
    private func finalizeMutation(_ response: VaultMacResponse, request: VaultMacRequest, signature: Data,
                                  now: Date, committedStateChanged: Bool, storedResponse: VaultMacResponse) throws {
        if response.status == .accepted || response.status == .partial {
            manifest.idempotency[request.idempotencyKey] = IdempotencyRecord(signature: signature,
                response: storedResponse, createdAt: now)
            trimIdempotency()
            try persistManifest()
        }
        if committedStateChanged { try cleanupCommittedState(for: request.objectID) }
        if request.operation == .putChunk, response.status == .accepted,
           let revision = request.revision { try removeChunkFiles(objectID: request.objectID, revision: revision.revision) }
    }

    /// Strips the per-chunk `receivedChunks` array before a putChunk response
    /// is memoized: keeping the whole growing list in each chunk's
    /// idempotency record made the manifest grow O(n^2) in chunk count,
    /// wedging uploads near 9.4 GiB against the documented 100 GiB contract.
    private func putChunkStorageResponse(_ response: VaultMacResponse) -> VaultMacResponse {
        VaultMacResponse(status: response.status, objectID: response.objectID,
            currentRevision: response.currentRevision, revision: response.revision,
            totalCiphertextBytes: response.totalCiphertextBytes, message: response.message,
            objectKind: response.objectKind, payloadGeneration: response.payloadGeneration)
    }

    /// Rebuilds `receivedChunks` from live upload state on replay, the way
    /// `readRange` rebuilds its answer from disk rather than a stored copy —
    /// so a replay always reflects chunks received so far, not a value frozen
    /// back when this particular chunk request first landed.
    private func replayedPutChunkResponse(_ stored: VaultMacResponse, for request: VaultMacRequest) -> VaultMacResponse {
        guard stored.status == .partial || stored.status == .accepted,
              let revision = request.revision else { return stored }
        let key = request.objectID.rawValue.uuidString
        let receivedChunks: [UInt32]
        if let object = manifest.objects[key], !object.deleted, object.revision.revision == revision.revision {
            receivedChunks = Array(0..<object.totalChunks)
        } else if let partial = manifest.partialUploads[key], partial.revision.revision == revision.revision {
            receivedChunks = Array(partial.receivedChunks)
        } else {
            receivedChunks = []
        }
        return VaultMacResponse(status: stored.status, objectID: stored.objectID,
            currentRevision: stored.currentRevision, revision: stored.revision,
            receivedChunks: receivedChunks, totalCiphertextBytes: stored.totalCiphertextBytes,
            message: stored.message, objectKind: stored.objectKind, payloadGeneration: stored.payloadGeneration)
    }

    public func currentRevision(for objectID: VaultObjectID) -> VaultRevision? {
        manifest.objects[objectID.rawValue.uuidString]?.revision
    }
    public func storedObjectCount() -> Int { manifest.objects.values.filter { !$0.deleted }.count }

    /// Re-encrypts the manifest under a newly paired credential. The caller
    /// must persist the same credential in its owner-only credential store and
    /// recreate the listener after this succeeds. If the durable write fails,
    /// this actor keeps using the old credential and manifest.
    public func rotateCredential(to replacement: VaultMacPairingCredential) throws {
        guard replacement.revokedAt == nil,
              replacement.pairingID == credential.pairingID,
              replacement.epoch > credential.epoch else {
            throw VaultMacProtocolError.invalidSecret
        }
        let previous = credential
        credential = replacement
        do {
            try persistManifest()
        } catch {
            credential = previous
            throw error
        }
    }

    private func stat(_ request: VaultMacRequest) -> VaultMacResponse {
        guard let object = manifest.objects[request.objectID.rawValue.uuidString] else {
            return VaultMacResponse(status: .notFound, objectID: request.objectID)
        }
        if object.deleted {
            return VaultMacResponse(status: .notFound, objectID: request.objectID,
                revision: object.revision, totalCiphertextBytes: 0)
        }
        return VaultMacResponse(status: .accepted, objectID: request.objectID,
            revision: object.revision, totalCiphertextBytes: object.totalBytes,
            objectKind: object.objectKind, payloadGeneration: object.payloadGeneration)
    }

    /// The second element reports whether the set of retained revision
    /// directories changed — a fresh commit, or a stale partial just
    /// discarded — so the caller only pays for `cleanupCommittedState`'s
    /// directory scan and fsync when there is actually something to prune.
    private func putChunk(_ request: VaultMacRequest, now: Date) throws -> (response: VaultMacResponse, committedStateChanged: Bool) {
        guard let revision = request.revision, let index = request.chunkIndex,
              let totalChunks = request.totalChunks, let totalBytes = request.totalCiphertextBytes,
              let ciphertext = request.ciphertext,
              let objectKind = request.objectKind,
              let payloadGeneration = request.payloadGeneration else {
            throw VaultMacCompanionError.invalidRevision
        }
        try validateChunkShape(totalBytes: totalBytes, totalChunks: totalChunks, index: index, chunkBytes: ciphertext.count)
        let key = request.objectID.rawValue.uuidString
        if let current = manifest.objects[key] {
            let order = compare(revision, current.revision)
            guard request.expectedRevision == current.revision.revision, order > 0 else {
                return (VaultMacResponse(status: .conflict, objectID: request.objectID, revision: current.revision), false)
            }
        } else if request.expectedRevision != nil {
            return (VaultMacResponse(status: .conflict, objectID: request.objectID), false)
        }
        var partial: PartialUpload
        var discardedStalePartial = false
        if let existingPartial = manifest.partialUploads[key] {
            if existingPartial.revision.revision == revision.revision {
                partial = existingPartial
            } else if compare(revision, existingPartial.revision) > 0 {
                // A strictly newer revision supersedes a stale partial rather
                // than conflicting forever. Without this, a client that lost
                // its own pending-upload record (crash, reinstall) mints a
                // new revision on every retry and wedges against the old
                // partial for up to `partialUploadLifetime` (7 days).
                partial = PartialUpload(revision: revision, totalBytes: totalBytes, totalChunks: totalChunks,
                    receivedChunks: [], receivedBytes: 0, updatedAt: now, objectKind: objectKind,
                    payloadGeneration: payloadGeneration)
                discardedStalePartial = true
            } else {
                return (VaultMacResponse(status: .conflict, objectID: request.objectID, revision: existingPartial.revision), false)
            }
        } else {
            guard manifest.partialUploads.count < limits.maximumPartialUploads else {
                throw VaultMacCompanionError.tooManyPartials
            }
            partial = PartialUpload(revision: revision, totalBytes: totalBytes, totalChunks: totalChunks,
                receivedChunks: [], receivedBytes: 0, updatedAt: now, objectKind: objectKind,
                payloadGeneration: payloadGeneration)
        }
        guard partial.totalBytes == totalBytes, partial.totalChunks == totalChunks,
              partial.objectKind == objectKind,
              partial.payloadGeneration == payloadGeneration else { throw VaultMacCompanionError.conflict }
        let directory = objectDirectoryURL(for: request.objectID, revision: revision.revision)
        let chunkURL = directory.appendingPathComponent("chunk-\(index).bin")
        if VaultSecureFileSystem.exists(chunkURL) {
            guard try VaultSecureFileSystem.read(chunkURL, maximumBytes: VaultMacProtocol.maximumTransferBytes) == ciphertext else { throw VaultMacCompanionError.conflict }
        } else {
            let projected = try checkedAdd(storedAndPartialBytes(), UInt64(ciphertext.count))
            guard projected <= limits.maximumStoredBytes else { throw VaultMacCompanionError.quotaExceeded }
            _ = try objectDirectory(for: request.objectID, revision: revision.revision)
            try VaultSecureFileSystem.atomicWrite(ciphertext, to: chunkURL,
                                                  maximumBytes: VaultMacProtocol.maximumTransferBytes)
            partial.receivedBytes = try checkedAdd(partial.receivedBytes, UInt64(ciphertext.count))
        }
        partial.receivedChunks.insert(index)
        partial.updatedAt = now; manifest.partialUploads[key] = partial
        guard partial.receivedChunks.count == Int(totalChunks) else {
            return (VaultMacResponse(status: .partial, objectID: request.objectID,
                receivedChunks: Array(partial.receivedChunks), totalCiphertextBytes: totalBytes), discardedStalePartial)
        }
        guard partial.receivedBytes == totalBytes else { throw VaultMacCompanionError.incompleteUpload }
        try assemble(objectID: request.objectID, revision: revision.revision, totalChunks: totalChunks,
                     expectedBytes: totalBytes)
        // The Mac is a blind encrypted-object gateway. It cannot unwrap the
        // DEK, but it must authenticate the complete LVF framing, identity,
        // ordering, and generation digest before publishing the object.
        guard let expected = try? VaultRemoteObjectIdentity(objectID: request.objectID,
                revision: revision.revision, kind: objectKind, generation: payloadGeneration) else {
            throw VaultMacCompanionError.conflict
        }
        let assembledCiphertext = objectDirectoryURL(for: request.objectID, revision: revision.revision)
            .appendingPathComponent("ciphertext.bin")
        guard (try? VaultAuthenticatedCiphertextFile(fileURL: assembledCiphertext,
                expectedIdentity: expected, vaultID: "default")) != nil else {
            throw VaultMacCompanionError.conflict
        }
        manifest.objects[key] = StoredObject(revision: revision, totalBytes: totalBytes,
                                             totalChunks: totalChunks, deleted: false,
                                             objectKind: objectKind,
                                             payloadGeneration: payloadGeneration)
        manifest.partialUploads.removeValue(forKey: key)
        return (VaultMacResponse(status: .accepted, objectID: request.objectID, revision: revision,
            receivedChunks: Array(partial.receivedChunks), totalCiphertextBytes: totalBytes,
            objectKind: objectKind, payloadGeneration: payloadGeneration), true)
    }

    private func readRange(_ request: VaultMacRequest) throws -> VaultMacResponse {
        guard let object = manifest.objects[request.objectID.rawValue.uuidString], !object.deleted else {
            return VaultMacResponse(status: .notFound, objectID: request.objectID)
        }
        guard let offset = request.offset, let length = request.length,
              offset <= object.totalBytes, length <= object.totalBytes - offset else { throw VaultMacCompanionError.invalidRange }
        let file = try objectDirectory(for: request.objectID, revision: object.revision.revision)
            .appendingPathComponent("ciphertext.bin")
        let bytes = try VaultSecureFileSystem.readRange(file, offset: offset, length: Int(length),
                                                        expectedFileBytes: object.totalBytes)
        guard UInt64(bytes.count) == length else { throw VaultMacCompanionError.diskFailure }
        return VaultMacResponse(status: .accepted, objectID: request.objectID,
            revision: object.revision, totalCiphertextBytes: object.totalBytes, ciphertext: bytes,
            objectKind: object.objectKind, payloadGeneration: object.payloadGeneration)
    }

    private func delete(_ request: VaultMacRequest) throws -> (response: VaultMacResponse, committedStateChanged: Bool) {
        let key = request.objectID.rawValue.uuidString
        guard let current = manifest.objects[key] else {
            return (VaultMacResponse(status: .notFound, objectID: request.objectID), false)
        }
        guard let tombstone = request.revision,
              request.expectedRevision == current.revision.revision,
              compare(tombstone, current.revision) > 0 else {
            return (VaultMacResponse(status: .conflict, objectID: request.objectID, revision: current.revision), false)
        }
        manifest.objects[key] = StoredObject(revision: tombstone, totalBytes: 0,
                                             totalChunks: 0, deleted: true)
        manifest.partialUploads.removeValue(forKey: key)
        return (VaultMacResponse(status: .accepted, objectID: request.objectID, revision: tombstone), true)
    }

    private func validateChunkShape(totalBytes: UInt64, totalChunks: UInt32,
                                    index: UInt32, chunkBytes: Int) throws {
        guard totalBytes > 0, totalBytes <= limits.maximumObjectBytes,
              totalChunks > 0, totalChunks <= VaultMacProtocol.maximumChunks,
              index < totalChunks, chunkBytes > 0,
              chunkBytes <= VaultMacProtocol.maximumTransferBytes else { throw VaultMacCompanionError.invalidRange }
        let (roundedBytes, overflow) = totalBytes.addingReportingOverflow(
            UInt64(VaultMacProtocol.maximumTransferBytes) - 1)
        guard !overflow else { throw VaultMacCompanionError.invalidRange }
        let minimumChunks = roundedBytes / UInt64(VaultMacProtocol.maximumTransferBytes)
        guard UInt64(totalChunks) >= minimumChunks, UInt64(totalChunks) <= totalBytes else {
            throw VaultMacCompanionError.invalidRange
        }
    }

    private func objectDirectory(for objectID: VaultObjectID, revision: UUID) throws -> URL {
        let object = rootURL.appendingPathComponent("objects", isDirectory: true)
            .appendingPathComponent(objectID.rawValue.uuidString, isDirectory: true)
        let revisionURL = objectDirectoryURL(for: objectID, revision: revision)
        try VaultSecureFileSystem.ensureDirectory(object); try VaultSecureFileSystem.ensureDirectory(revisionURL)
        return revisionURL
    }

    private func objectDirectoryURL(for objectID: VaultObjectID, revision: UUID) -> URL {
        rootURL.appendingPathComponent("objects", isDirectory: true)
            .appendingPathComponent(objectID.rawValue.uuidString, isDirectory: true)
            .appendingPathComponent(revision.uuidString, isDirectory: true)
    }

    private func assemble(objectID: VaultObjectID, revision: UUID,
                          totalChunks: UInt32, expectedBytes: UInt64) throws {
        let directory = try objectDirectory(for: objectID, revision: revision)
        let staging = directory.appendingPathComponent(".ciphertext-staging-\(UUID().uuidString)")
        let fd = try VaultSecureFileSystem.openNew(staging)
        defer { close(fd) }
        var written: UInt64 = 0
        for index in 0..<totalChunks {
            if Task.isCancelled { throw VaultMacCompanionError.diskFailure }
            let chunk = try VaultSecureFileSystem.read(directory.appendingPathComponent("chunk-\(index).bin"),
                                                       maximumBytes: VaultMacProtocol.maximumTransferBytes)
            try VaultSecureFileSystem.writeAll(chunk, fd: fd)
            written = try checkedAdd(written, UInt64(chunk.count))
        }
        guard written == expectedBytes, fsync(fd) == 0 else { throw VaultMacCompanionError.incompleteUpload }
        try VaultSecureFileSystem.install(staging, at: directory.appendingPathComponent("ciphertext.bin"))
    }

    private func removeChunkFiles(objectID: VaultObjectID, revision: UUID) throws {
        let directory = objectDirectoryURL(for: objectID, revision: revision)
        guard VaultSecureFileSystem.exists(directory) else { return }
        let children = try VaultSecureFileSystem.directoryContents(directory)
        for child in children where child.lastPathComponent.hasPrefix("chunk-") {
            try VaultSecureFileSystem.removeRegularFile(child)
        }
        try VaultSecureFileSystem.syncDirectory(directory)
    }

    private func cleanupCommittedState(for objectID: VaultObjectID) throws {
        let key = objectID.rawValue.uuidString
        var retained: Set<String> = []
        if let object = manifest.objects[key], !object.deleted {
            retained.insert(object.revision.revision.uuidString)
        }
        if let partial = manifest.partialUploads[key] {
            retained.insert(partial.revision.revision.uuidString)
        }
        let objectURL = rootURL.appendingPathComponent("objects", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
        guard VaultSecureFileSystem.exists(objectURL) else { return }
        try VaultSecureFileSystem.ensureDirectory(objectURL)
        for child in try VaultSecureFileSystem.directoryContents(objectURL) where !retained.contains(child.lastPathComponent) {
            try VaultSecureFileSystem.removeTree(child)
        }
        if retained.isEmpty {
            try VaultSecureFileSystem.removeTree(objectURL)
        } else {
            try VaultSecureFileSystem.syncDirectory(objectURL)
        }
    }

    private func storedAndPartialBytes() throws -> UInt64 {
        var total: UInt64 = 0
        for object in manifest.objects.values where !object.deleted { total = try checkedAdd(total, object.totalBytes) }
        for partial in manifest.partialUploads.values { total = try checkedAdd(total, partial.receivedBytes) }
        return total
    }

    private func trimIdempotency() {
        if manifest.idempotency.count > 10_000 {
            let remove = manifest.idempotency.sorted { $0.value.createdAt < $1.value.createdAt }
                .prefix(manifest.idempotency.count - 10_000).map(\.key)
            for key in remove { manifest.idempotency.removeValue(forKey: key) }
        }
    }

    private func persistManifest() throws {
        try Self.writeManifest(manifest, rootURL: rootURL, credential: credential, limits: limits)
    }

    private static func writeManifest(_ manifest: CompanionManifest, rootURL: URL,
                                      credential: VaultMacPairingCredential,
                                      limits: VaultMacCompanionLimits) throws {
        let plaintext = try JSONEncoder().encode(manifest)
        guard plaintext.count <= limits.maximumManifestBytes else { throw VaultMacCompanionError.manifestTooLarge }
        let nonce = AES.GCM.Nonce(), aad = Data("LunaVault-Mac-manifest-v2".utf8)
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: credential.secret.rawValue),
                                   nonce: nonce, authenticating: aad)
        let envelope = ManifestEnvelope(nonce: Data(nonce), ciphertext: Data(box.ciphertext), tag: Data(box.tag))
        // JSON/base64 expands the authenticated manifest; bound the encoded
        // envelope separately while keeping the plaintext limit authoritative.
        let encodedEnvelope = try JSONEncoder().encode(envelope)
        let envelopeLimit = min(Int.max / 2, max(limits.maximumManifestBytes + 1_024,
                                                 limits.maximumManifestBytes * 2))
        try VaultSecureFileSystem.atomicWrite(encodedEnvelope,
            to: rootURL.appendingPathComponent("manifest.v2"), maximumBytes: envelopeLimit)
    }

    private static func loadManifest(rootURL: URL, credential: VaultMacPairingCredential,
                                     limits: VaultMacCompanionLimits) throws -> CompanionManifest {
        let url = rootURL.appendingPathComponent("manifest.v2")
        guard VaultSecureFileSystem.exists(url) else { return CompanionManifest() }
        do {
            let envelope = try JSONDecoder().decode(ManifestEnvelope.self,
                from: VaultSecureFileSystem.read(url, maximumBytes: min(Int.max / 2,
                    max(limits.maximumManifestBytes + 1_024, limits.maximumManifestBytes * 2))))
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: envelope.nonce),
                                            ciphertext: envelope.ciphertext, tag: envelope.tag)
            let data = try AES.GCM.open(box, using: SymmetricKey(data: credential.secret.rawValue),
                                       authenticating: Data("LunaVault-Mac-manifest-v2".utf8))
            guard data.count <= limits.maximumManifestBytes else { throw VaultMacCompanionError.manifestTooLarge }
            return try JSONDecoder().decode(CompanionManifest.self, from: data)
        } catch let error as VaultMacCompanionError { throw error }
        catch { throw VaultMacCompanionError.diskFailure }
    }

    private static func recover(rootURL: URL, manifest: inout CompanionManifest,
                                limits: VaultMacCompanionLimits, now: Date) throws {
        manifest.partialUploads = manifest.partialUploads.filter {
            now.timeIntervalSince($0.value.updatedAt) <= limits.partialUploadLifetime
        }
        manifest.idempotency = manifest.idempotency.filter {
            now.timeIntervalSince($0.value.createdAt) <= 30 * 24 * 60 * 60
        }
        let objects = rootURL.appendingPathComponent("objects", isDirectory: true)
        guard VaultSecureFileSystem.exists(objects) else { return }
        var retained: [String: [String: Set<String>]] = [:]
        for (key, object) in manifest.objects where !object.deleted {
            retained[key, default: [:]][object.revision.revision.uuidString, default: []].insert("ciphertext.bin")
        }
        for (key, partial) in manifest.partialUploads {
            for chunk in partial.receivedChunks {
                retained[key, default: [:]][partial.revision.revision.uuidString, default: []]
                    .insert("chunk-\(chunk).bin")
            }
        }
        var budget = VaultMacRecoveryBudget(maximumEntries: limits.maximumRecoveryEntries)
        func boundedContents(_ url: URL) throws -> [URL] {
            let entries = try VaultSecureFileSystem.directoryContents(
                url, maximumEntries: budget.remaining)
            for _ in entries { try budget.inspectEntry() }
            return entries
        }
        for objectURL in try boundedContents(objects) {
            guard let revisions = retained[objectURL.lastPathComponent] else {
                try VaultSecureFileSystem.removeTree(objectURL, recoveryBudget: &budget)
                continue
            }
            try VaultSecureFileSystem.ensureDirectory(objectURL)
            for revisionURL in try boundedContents(objectURL) {
                guard let allowedFiles = revisions[revisionURL.lastPathComponent] else {
                    try VaultSecureFileSystem.removeTree(revisionURL, recoveryBudget: &budget)
                    continue
                }
                try VaultSecureFileSystem.ensureDirectory(revisionURL)
                for fileURL in try boundedContents(revisionURL) {
                    if allowedFiles.contains(fileURL.lastPathComponent) {
                        // A symlink occupying an expected ciphertext/chunk name
                        // is not an orphan we can silently unlink: fail startup
                        // closed so no manifest-authorized path is ever followed.
                        try VaultSecureFileSystem.rejectSymlink(fileURL)
                    } else {
                        try VaultSecureFileSystem.removeTree(fileURL, recoveryBudget: &budget)
                    }
                }
            }
        }
        try VaultSecureFileSystem.syncDirectory(objects)
    }

    private func compare(_ lhs: VaultRevision, _ rhs: VaultRevision) -> Int {
        if lhs.logicalTime != rhs.logicalTime { return lhs.logicalTime < rhs.logicalTime ? -1 : 1 }
        if lhs.deviceID != rhs.deviceID { return lhs.deviceID < rhs.deviceID ? -1 : 1 }
        if lhs.revision == rhs.revision { return 0 }
        return lhs.revision.uuidString < rhs.revision.uuidString ? -1 : 1
    }
}

public actor VaultMacCompanionService {
    private let store: VaultMacCompanionStore
    public init(store: VaultMacCompanionStore) { self.store = store }
    public func handle(_ request: VaultMacRequest) async -> VaultMacResponse {
        do { return try await store.handle(request) }
        catch VaultMacCompanionError.conflict { return VaultMacResponse(status: .conflict, objectID: request.objectID) }
        catch VaultMacCompanionError.quotaExceeded { return VaultMacResponse(status: .quotaExceeded, objectID: request.objectID) }
        catch { return VaultMacResponse(status: .invalid, objectID: request.objectID, message: "request rejected") }
    }
}

private enum VaultSecureFileSystem {
    static func exists(_ url: URL) -> Bool {
        #if canImport(Darwin)
        var info = stat()
        return lstat(url.path, &info) == 0
        #else
        return false
        #endif
    }
    static func ensureDirectory(_ url: URL) throws {
        #if canImport(Darwin)
        let components = try validatedComponents(url.path)
        // Walk from a stable root descriptor.  Opening the complete path and
        // creating missing descendants afterwards reintroduces a race at the
        // first missing component; mkdirat/openat keeps every component
        // decision anchored and rejects an intermediate symlink.
        var directory = Darwin.open(url.path.hasPrefix("/") ? "/" : ".",
                                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else {
            let failure = errno
            throw (failure == ELOOP || failure == ENOTDIR)
                ? VaultMacCompanionError.symlinkRejected : VaultMacCompanionError.diskFailure
        }
        for component in components {
            var created = false
            var next = component.withCString {
                Darwin.openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            }
            if next < 0, errno == ENOENT {
                let made = component.withCString { Darwin.mkdirat(directory, $0, 0o700) }
                guard made == 0 || errno == EEXIST else {
                    let failure = errno
                    close(directory)
                    throw (failure == ELOOP || failure == ENOTDIR)
                        ? VaultMacCompanionError.symlinkRejected : VaultMacCompanionError.diskFailure
                }
                created = made == 0
                next = component.withCString {
                    Darwin.openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                }
            }
            guard next >= 0 else {
                let failure = errno
                close(directory)
                throw (failure == ELOOP || failure == ENOTDIR)
                    ? VaultMacCompanionError.symlinkRejected : VaultMacCompanionError.diskFailure
            }
            // Never chmod an OS-owned ancestor such as `/Users` or `/private`.
            // Newly created Vault descendants are private by construction;
            // existing app-owned directories retain their established mode.
            guard !created || fchmod(next, 0o700) == 0 else {
                close(next); close(directory); throw VaultMacCompanionError.diskFailure
            }
            close(directory)
            directory = next
        }
        close(directory)
        #else
        throw VaultMacCompanionError.diskFailure
        #endif
    }
    static func rejectSymlink(_ url: URL) throws {
        #if canImport(Darwin)
        let (parent, name) = try openParent(url.path)
        defer { close(parent) }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw VaultMacCompanionError.diskFailure
        }
        guard (info.st_mode & S_IFMT) != S_IFLNK else { throw VaultMacCompanionError.symlinkRejected }
        #endif
    }
    static func directoryContents(_ url: URL, maximumEntries: Int? = nil) throws -> [URL] {
        #if canImport(Darwin)
        let fd = try openDirectory(url.path)
        guard let stream = fdopendir(fd) else {
            close(fd)
            throw VaultMacCompanionError.diskFailure
        }
        defer { _ = closedir(stream) }
        var contents: [URL] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            if let maximumEntries, contents.count >= maximumEntries {
                throw VaultMacCompanionError.tooManyPartials
            }
            contents.append(url.appendingPathComponent(name))
        }
        return contents
        #else
        throw VaultMacCompanionError.diskFailure
        #endif
    }
    static func openNew(_ url: URL) throws -> Int32 {
        #if canImport(Darwin)
        let (parent, name) = try openParent(url.path)
        defer { close(parent) }
        let fd = name.withCString {
            Darwin.openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                          S_IRUSR | S_IWUSR)
        }
        guard fd >= 0 else {
            let failure = errno
            throw (failure == ELOOP || failure == ENOTDIR)
                ? VaultMacCompanionError.symlinkRejected : VaultMacCompanionError.diskFailure
        }
        return fd
        #else
        throw VaultMacCompanionError.diskFailure
        #endif
    }
    static func atomicWrite(_ data: Data, to url: URL, maximumBytes: Int) throws {
        guard data.count <= maximumBytes else { throw VaultMacCompanionError.manifestTooLarge }
        try ensureDirectory(url.deletingLastPathComponent())
        if exists(url) { try rejectSymlink(url) }
        let staging = url.deletingLastPathComponent().appendingPathComponent(".staging-\(UUID().uuidString)")
        let fd = try openNew(staging); defer { close(fd) }
        do {
            try writeAll(data, fd: fd)
            guard fsync(fd) == 0 else { throw VaultMacCompanionError.diskFailure }
            try install(staging, at: url)
            // `rename` preserves the staging mode, but reassert it after
            // installation so an existing file can never weaken the contract
            // through an unusual filesystem or a future writer change.
            #if canImport(Darwin)
            let installed = try openRegular(url.path)
            defer { close(installed) }
            guard fchmod(installed, S_IRUSR | S_IWUSR) == 0 else {
                throw VaultMacCompanionError.diskFailure
            }
            #endif
        }
        catch { try? removeRegularFile(staging); throw error }
    }
    static func install(_ source: URL, at destination: URL) throws {
        if exists(destination) { try rejectSymlink(destination) }
        #if canImport(Darwin)
        let (sourceParent, sourceName) = try openParent(source.path)
        defer { close(sourceParent) }
        let (destinationParent, destinationName) = try openParent(destination.path)
        defer { close(destinationParent) }
        guard renameat(sourceParent, sourceName, destinationParent, destinationName) == 0 else {
            throw VaultMacCompanionError.diskFailure
        }
        try syncDirectory(destination.deletingLastPathComponent())
        #else
        throw VaultMacCompanionError.diskFailure
        #endif
    }
    static func writeAll(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                guard count > 0 else { throw VaultMacCompanionError.diskFailure }; offset += count
            }
        }
    }
    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        #if canImport(Darwin)
        let fd = try openRegular(url.path)
        defer { close(fd) }; var info = stat(); guard fstat(fd, &info) == 0,
            (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0,
            info.st_size <= maximumBytes else { throw VaultMacCompanionError.diskFailure }
        return try readFD(fd, count: Int(info.st_size), offset: 0)
        #else
        throw VaultMacCompanionError.diskFailure
        #endif
    }
    static func readRange(_ url: URL, offset: UInt64, length: Int, expectedFileBytes: UInt64) throws -> Data {
        #if canImport(Darwin)
        let fd = try openRegular(url.path)
        defer { close(fd) }; var info = stat(); guard fstat(fd, &info) == 0,
            (info.st_mode & S_IFMT) == S_IFREG, UInt64(info.st_size) == expectedFileBytes,
            offset <= expectedFileBytes, UInt64(length) <= expectedFileBytes - offset else { throw VaultMacCompanionError.invalidRange }
        return try readFD(fd, count: length, offset: off_t(offset))
        #else
        throw VaultMacCompanionError.diskFailure
        #endif
    }
    private static func readFD(_ fd: Int32, count: Int, offset: off_t) throws -> Data {
        var data = Data(count: count)
        let readCount = data.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            var done = 0
            while done < count {
                let value = pread(fd, base.advanced(by: done), count - done, offset + off_t(done))
                if value <= 0 { return -1 }; done += value
            }
            return done
        }
        guard readCount == count else { throw VaultMacCompanionError.diskFailure }; return data
    }
    static func removeRegularFile(_ url: URL) throws {
        #if canImport(Darwin)
        let (parent, name) = try openParent(url.path)
        defer { close(parent) }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw VaultMacCompanionError.diskFailure
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw (info.st_mode & S_IFMT) == S_IFLNK
                ? VaultMacCompanionError.symlinkRejected : VaultMacCompanionError.diskFailure
        }
        guard unlinkat(parent, name, 0) == 0 else { throw VaultMacCompanionError.diskFailure }
        #else
        throw VaultMacCompanionError.diskFailure
        #endif
    }
    static func removeTree(_ url: URL) throws {
        #if canImport(Darwin)
        // Resolve the entry from a stable parent descriptor and recurse with
        // directory FDs. A path-based lstat/contentsOfDirectory/unlink
        // sequence permits an intermediate directory or child to be swapped
        // between the check and the mutation.
        let (parent, name) = try openParent(url.path)
        defer { close(parent) }
        try removeEntry(parent: parent, name: name)
        guard fsync(parent) == 0 else { throw VaultMacCompanionError.diskFailure }
        #else
        throw VaultMacCompanionError.diskFailure
        #endif
    }

    /// Recovery-only deletion.  Every entry, including the root entry being
    /// removed, consumes the caller's shared budget and checks cancellation
    /// before descending.  This keeps a crash-orphaned deep or wide subtree
    /// from turning initialization into an unbounded recursive walk.
    static func removeTree(_ url: URL,
                           recoveryBudget budget: inout VaultMacRecoveryBudget) throws {
        #if canImport(Darwin)
        let (parent, name) = try openParent(url.path)
        defer { close(parent) }
        try removeEntry(parent: parent, name: name, recoveryBudget: &budget)
        guard fsync(parent) == 0 else { throw VaultMacCompanionError.diskFailure }
        #else
        throw VaultMacCompanionError.diskFailure
        #endif
    }

    #if canImport(Darwin)
    private static func removeEntry(parent: Int32, name: String) throws {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw VaultMacCompanionError.diskFailure
        }
        let kind = info.st_mode & S_IFMT
        if kind == S_IFLNK || kind == S_IFREG {
            guard name.withCString({ unlinkat(parent, $0, 0) }) == 0 else {
                throw VaultMacCompanionError.diskFailure
            }
            return
        }
        guard kind == S_IFDIR else { throw VaultMacCompanionError.diskFailure }
        let directory = name.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard directory >= 0 else {
            throw errno == ELOOP ? VaultMacCompanionError.symlinkRejected : VaultMacCompanionError.diskFailure
        }
        let stream = fdopendir(directory)
        guard let stream else { close(directory); throw VaultMacCompanionError.diskFailure }
        // fdopendir owns `directory` from this point through closedir.
        while let entry = readdir(stream) {
            let rawName = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            guard rawName != ".", rawName != ".." else { continue }
            try removeEntry(parent: dirfd(stream), name: rawName)
        }
        guard closedir(stream) == 0 else { throw VaultMacCompanionError.diskFailure }
        guard name.withCString({ unlinkat(parent, $0, AT_REMOVEDIR) }) == 0 else {
            throw VaultMacCompanionError.diskFailure
        }
    }

    private static func removeEntry(parent: Int32, name: String,
                                    recoveryBudget budget: inout VaultMacRecoveryBudget) throws {
        try budget.inspectEntry()
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw VaultMacCompanionError.diskFailure
        }
        let kind = info.st_mode & S_IFMT
        if kind == S_IFLNK || kind == S_IFREG {
            guard name.withCString({ unlinkat(parent, $0, 0) }) == 0 else {
                throw VaultMacCompanionError.diskFailure
            }
            return
        }
        guard kind == S_IFDIR else { throw VaultMacCompanionError.diskFailure }
        guard !Task.isCancelled else { throw VaultMacCompanionError.recoveryCancelled }
        let directory = name.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard directory >= 0 else {
            throw errno == ELOOP ? VaultMacCompanionError.symlinkRejected : VaultMacCompanionError.diskFailure
        }
        let stream = fdopendir(directory)
        guard let stream else { close(directory); throw VaultMacCompanionError.diskFailure }
        // fdopendir owns `directory` from this point through closedir.
        while let entry = readdir(stream) {
            let rawName = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            guard rawName != ".", rawName != ".." else { continue }
            try removeEntry(parent: dirfd(stream), name: rawName, recoveryBudget: &budget)
        }
        guard closedir(stream) == 0 else { throw VaultMacCompanionError.diskFailure }
        guard name.withCString({ unlinkat(parent, $0, AT_REMOVEDIR) }) == 0 else {
            throw VaultMacCompanionError.diskFailure
        }
    }
    #endif
    static func syncDirectory(_ url: URL) throws {
        #if canImport(Darwin)
        let fd = try openDirectory(url.path)
        guard fd >= 0 else { throw VaultMacCompanionError.diskFailure }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw VaultMacCompanionError.diskFailure }
        #endif
    }

    #if canImport(Darwin)
    private static func validatedComponents(_ path: String) throws -> [String] {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.contains("."), !components.contains("..") else {
            throw VaultMacCompanionError.symlinkRejected
        }
        return components
    }

    private static func openDirectory(_ path: String) throws -> Int32 {
        let components = try validatedComponents(path)
        var fd = Darwin.open(path.hasPrefix("/") ? "/" : ".",
                             O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else {
            let failure = errno
            throw (failure == ELOOP || failure == ENOTDIR)
                ? VaultMacCompanionError.symlinkRejected : VaultMacCompanionError.diskFailure
        }
        for component in components {
            let next = component.withCString {
                Darwin.openat(fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            }
            guard next >= 0 else {
                let failure = errno
                close(fd)
                throw (failure == ELOOP || failure == ENOTDIR)
                    ? VaultMacCompanionError.symlinkRejected : VaultMacCompanionError.diskFailure
            }
            close(fd); fd = next
        }
        return fd
    }

    private static func openParent(_ path: String) throws -> (Int32, String) {
        let components = try validatedComponents(path)
        guard let name = components.last else { throw VaultMacCompanionError.diskFailure }
        let parentPath = path.hasPrefix("/")
            ? "/" + components.dropLast().joined(separator: "/")
            : components.dropLast().joined(separator: "/")
        let parent = try openDirectory(parentPath.isEmpty ? "." : parentPath)
        return (parent, name)
    }

    private static func openRegular(_ path: String) throws -> Int32 {
        let (parent, name) = try openParent(path)
        defer { close(parent) }
        let fd = name.withCString { Darwin.openat(parent, $0, O_RDONLY | O_NOFOLLOW) }
        guard fd >= 0 else {
            throw errno == ELOOP ? VaultMacCompanionError.symlinkRejected : VaultMacCompanionError.diskFailure
        }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd); throw VaultMacCompanionError.diskFailure
        }
        return fd
    }
    #endif
}

private func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else { throw VaultMacCompanionError.quotaExceeded }; return value
}
private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}
private extension SymmetricKey { var data: Data { withUnsafeBytes { Data($0) } } }
private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}

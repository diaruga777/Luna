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
    case invalidRevision, objectNotFound, conflict, incompleteUpload, invalidRange
    case diskFailure, quotaExceeded, symlinkRejected, manifestTooLarge, tooManyPartials
}

public struct VaultMacCompanionLimits: Equatable, Sendable {
    public let maximumObjectBytes: UInt64
    public let maximumStoredBytes: UInt64
    public let maximumManifestBytes: Int
    public let maximumPartialUploads: Int
    public let partialUploadLifetime: TimeInterval
    public init(maximumObjectBytes: UInt64 = VaultMacProtocol.maximumObjectBytes,
                maximumStoredBytes: UInt64 = 1_099_511_627_776,
                maximumManifestBytes: Int = 16 * 1024 * 1024,
                maximumPartialUploads: Int = 64,
                partialUploadLifetime: TimeInterval = 7 * 24 * 60 * 60) {
        self.maximumObjectBytes = min(maximumObjectBytes, VaultMacProtocol.maximumObjectBytes)
        self.maximumStoredBytes = maximumStoredBytes
        self.maximumManifestBytes = maximumManifestBytes
        self.maximumPartialUploads = maximumPartialUploads
        self.partialUploadLifetime = partialUploadLifetime
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
        -> (VaultMacSessionChallenge, VaultMacSessionKeys) {
        try lock.withLock {
            guard !consumed.contains(response.sessionID),
                  let challenge = pending.removeValue(forKey: response.sessionID) else {
                throw VaultMacProtocolError.replayedFrame
            }
            let keys = try VaultMacSessionKeys(challenge: challenge, response: response,
                                               credential: credential, now: now)
            consumed.insert(response.sessionID)
            if consumed.count > 4_096 { consumed.removeAll(keepingCapacity: true) }
            return (challenge, keys)
        }
    }
    public func rotate(to credential: VaultMacPairingCredential) {
        lock.withLock { self.credential = credential; pending.removeAll(); consumed.removeAll() }
    }
    public func revoke(now: Date = Date()) throws {
        try lock.withLock { credential = try credential.revoked(now: now); pending.removeAll(); consumed.removeAll() }
    }
}

private struct StoredObject: Codable, Sendable {
    var revision: VaultRevision; var totalBytes: UInt64; var totalChunks: UInt32; var deleted: Bool
}
private struct PartialUpload: Codable, Sendable {
    var revision: VaultRevision; var totalBytes: UInt64; var totalChunks: UInt32
    var receivedChunks: [UInt32]; var receivedBytes: UInt64; var updatedAt: Date
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

public actor VaultMacCompanionStore {
    public let rootURL: URL
    private let credential: VaultMacPairingCredential
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
            try cleanupCommittedState(for: request.objectID)
            return existing.response
        }
        let response: VaultMacResponse
        switch request.operation {
        case .putChunk: response = try putChunk(request, now: now)
        case .stat: response = stat(request)
        case .readRange: response = try readRange(request)
        case .delete: response = try delete(request)
        }
        manifest.idempotency[request.idempotencyKey] = IdempotencyRecord(signature: signature, response: response, createdAt: now)
        trimIdempotency()
        try persistManifest()
        try cleanupCommittedState(for: request.objectID)
        if request.operation == .putChunk, response.status == .accepted,
           let revision = request.revision { try removeChunkFiles(objectID: request.objectID, revision: revision.revision) }
        return response
    }

    public func currentRevision(for objectID: VaultObjectID) -> VaultRevision? {
        manifest.objects[objectID.rawValue.uuidString]?.revision
    }
    public func storedObjectCount() -> Int { manifest.objects.values.filter { !$0.deleted }.count }

    private func stat(_ request: VaultMacRequest) -> VaultMacResponse {
        guard let object = manifest.objects[request.objectID.rawValue.uuidString], !object.deleted else {
            return VaultMacResponse(status: .notFound, objectID: request.objectID)
        }
        return VaultMacResponse(status: .accepted, objectID: request.objectID,
            revision: object.revision, totalCiphertextBytes: object.totalBytes)
    }

    private func putChunk(_ request: VaultMacRequest, now: Date) throws -> VaultMacResponse {
        guard let revision = request.revision, let index = request.chunkIndex,
              let totalChunks = request.totalChunks, let totalBytes = request.totalCiphertextBytes,
              let ciphertext = request.ciphertext else { throw VaultMacCompanionError.invalidRevision }
        try validateChunkShape(totalBytes: totalBytes, totalChunks: totalChunks, index: index, chunkBytes: ciphertext.count)
        let key = request.objectID.rawValue.uuidString
        if let current = manifest.objects[key] {
            let order = compare(revision, current.revision)
            guard request.expectedRevision == current.revision.revision, order > 0 else {
                return VaultMacResponse(status: .conflict, objectID: request.objectID, revision: current.revision)
            }
        } else if request.expectedRevision != nil {
            return VaultMacResponse(status: .conflict, objectID: request.objectID)
        }
        if manifest.partialUploads[key] == nil, manifest.partialUploads.count >= limits.maximumPartialUploads {
            throw VaultMacCompanionError.tooManyPartials
        }
        var partial = manifest.partialUploads[key] ?? PartialUpload(revision: revision,
            totalBytes: totalBytes, totalChunks: totalChunks, receivedChunks: [],
            receivedBytes: 0, updatedAt: now)
        guard partial.revision.revision == revision.revision, partial.totalBytes == totalBytes,
              partial.totalChunks == totalChunks else { throw VaultMacCompanionError.conflict }
        let directory = objectDirectoryURL(for: request.objectID, revision: revision.revision)
        let chunkURL = directory.appendingPathComponent("chunk-\(index).bin")
        if VaultSecureFileSystem.exists(chunkURL) {
            guard try VaultSecureFileSystem.read(chunkURL, maximumBytes: VaultMacProtocol.maximumFrameBytes) == ciphertext else { throw VaultMacCompanionError.conflict }
        } else {
            let projected = try checkedAdd(storedAndPartialBytes(), UInt64(ciphertext.count))
            guard projected <= limits.maximumStoredBytes else { throw VaultMacCompanionError.quotaExceeded }
            _ = try objectDirectory(for: request.objectID, revision: revision.revision)
            try VaultSecureFileSystem.atomicWrite(ciphertext, to: chunkURL,
                                                  maximumBytes: VaultMacProtocol.maximumFrameBytes)
            partial.receivedBytes = try checkedAdd(partial.receivedBytes, UInt64(ciphertext.count))
        }
        if !partial.receivedChunks.contains(index) { partial.receivedChunks.append(index); partial.receivedChunks.sort() }
        partial.updatedAt = now; manifest.partialUploads[key] = partial
        guard partial.receivedChunks.count == Int(totalChunks) else {
            return VaultMacResponse(status: .partial, objectID: request.objectID,
                receivedChunks: partial.receivedChunks, totalCiphertextBytes: totalBytes)
        }
        guard partial.receivedBytes == totalBytes else { throw VaultMacCompanionError.incompleteUpload }
        try assemble(objectID: request.objectID, revision: revision.revision, totalChunks: totalChunks,
                     expectedBytes: totalBytes)
        manifest.objects[key] = StoredObject(revision: revision, totalBytes: totalBytes,
                                             totalChunks: totalChunks, deleted: false)
        manifest.partialUploads.removeValue(forKey: key)
        return VaultMacResponse(status: .accepted, objectID: request.objectID, revision: revision,
            receivedChunks: partial.receivedChunks, totalCiphertextBytes: totalBytes)
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
            revision: object.revision, totalCiphertextBytes: object.totalBytes, ciphertext: bytes)
    }

    private func delete(_ request: VaultMacRequest) throws -> VaultMacResponse {
        let key = request.objectID.rawValue.uuidString
        guard let current = manifest.objects[key] else { return VaultMacResponse(status: .notFound, objectID: request.objectID) }
        guard let tombstone = request.revision,
              request.expectedRevision == current.revision.revision,
              compare(tombstone, current.revision) > 0 else {
            return VaultMacResponse(status: .conflict, objectID: request.objectID, revision: current.revision)
        }
        manifest.objects[key] = StoredObject(revision: tombstone, totalBytes: 0,
                                             totalChunks: 0, deleted: true)
        manifest.partialUploads.removeValue(forKey: key)
        return VaultMacResponse(status: .accepted, objectID: request.objectID, revision: tombstone)
    }

    private func validateChunkShape(totalBytes: UInt64, totalChunks: UInt32,
                                    index: UInt32, chunkBytes: Int) throws {
        guard totalBytes > 0, totalBytes <= limits.maximumObjectBytes,
              totalChunks > 0, index < totalChunks, chunkBytes > 0,
              chunkBytes <= VaultMacProtocol.maximumFrameBytes else { throw VaultMacCompanionError.invalidRange }
        let minimumChunks = (totalBytes + UInt64(VaultMacProtocol.maximumFrameBytes) - 1) /
                            UInt64(VaultMacProtocol.maximumFrameBytes)
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
            let chunk = try VaultSecureFileSystem.read(directory.appendingPathComponent("chunk-\(index).bin"),
                                                       maximumBytes: VaultMacProtocol.maximumFrameBytes)
            try VaultSecureFileSystem.writeAll(chunk, fd: fd)
            written = try checkedAdd(written, UInt64(chunk.count))
        }
        guard written == expectedBytes, fsync(fd) == 0 else { throw VaultMacCompanionError.incompleteUpload }
        try VaultSecureFileSystem.install(staging, at: directory.appendingPathComponent("ciphertext.bin"))
    }

    private func removeChunkFiles(objectID: VaultObjectID, revision: UUID) throws {
        let directory = objectDirectoryURL(for: objectID, revision: revision)
        guard VaultSecureFileSystem.exists(directory) else { return }
        let children = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
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
        try VaultSecureFileSystem.atomicWrite(try JSONEncoder().encode(envelope),
            to: rootURL.appendingPathComponent("manifest.v2"), maximumBytes: limits.maximumManifestBytes + 1_024)
    }

    private static func loadManifest(rootURL: URL, credential: VaultMacPairingCredential,
                                     limits: VaultMacCompanionLimits) throws -> CompanionManifest {
        let url = rootURL.appendingPathComponent("manifest.v2")
        guard VaultSecureFileSystem.exists(url) else { return CompanionManifest() }
        do {
            let envelope = try JSONDecoder().decode(ManifestEnvelope.self,
                from: VaultSecureFileSystem.read(url, maximumBytes: limits.maximumManifestBytes + 1_024))
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
        for objectURL in try VaultSecureFileSystem.directoryContents(objects) {
            guard let revisions = retained[objectURL.lastPathComponent] else {
                try VaultSecureFileSystem.removeTree(objectURL)
                continue
            }
            try VaultSecureFileSystem.ensureDirectory(objectURL)
            for revisionURL in try VaultSecureFileSystem.directoryContents(objectURL) {
                guard let allowedFiles = revisions[revisionURL.lastPathComponent] else {
                    try VaultSecureFileSystem.removeTree(revisionURL)
                    continue
                }
                try VaultSecureFileSystem.ensureDirectory(revisionURL)
                for fileURL in try VaultSecureFileSystem.directoryContents(revisionURL)
                    where !allowedFiles.contains(fileURL.lastPathComponent) {
                    try VaultSecureFileSystem.removeTree(fileURL)
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
        catch VaultMacCompanionError.objectNotFound { return VaultMacResponse(status: .notFound, objectID: request.objectID) }
        catch { return VaultMacResponse(status: .invalid, objectID: request.objectID, message: "request rejected") }
    }
}

private enum VaultSecureFileSystem {
    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    static func ensureDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw VaultMacCompanionError.diskFailure }
            try rejectSymlink(url); #if canImport(Darwin)
            guard chmod(url.path, 0o700) == 0 else { throw VaultMacCompanionError.diskFailure }
            #endif
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try rejectSymlink(url)
    }
    static func rejectSymlink(_ url: URL) throws {
        #if canImport(Darwin)
        var info = stat(); guard lstat(url.path, &info) == 0 else { throw VaultMacCompanionError.diskFailure }
        guard (info.st_mode & S_IFMT) != S_IFLNK else { throw VaultMacCompanionError.symlinkRejected }
        #endif
    }
    static func directoryContents(_ url: URL) throws -> [URL] {
        try ensureDirectory(url)
        return try FileManager.default.contentsOfDirectory(at: url,
            includingPropertiesForKeys: nil, options: [])
    }
    static func openNew(_ url: URL) throws -> Int32 {
        #if canImport(Darwin)
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw VaultMacCompanionError.diskFailure }; return fd
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
        do { try writeAll(data, fd: fd); guard fsync(fd) == 0 else { throw VaultMacCompanionError.diskFailure }; try install(staging, at: url) }
        catch { try? removeRegularFile(staging); throw error }
    }
    static func install(_ source: URL, at destination: URL) throws {
        if exists(destination) { try rejectSymlink(destination) }
        #if canImport(Darwin)
        guard rename(source.path, destination.path) == 0 else { throw VaultMacCompanionError.diskFailure }
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
        try rejectSymlink(url)
        #if canImport(Darwin)
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW); guard fd >= 0 else { throw VaultMacCompanionError.diskFailure }
        defer { close(fd) }; var info = stat(); guard fstat(fd, &info) == 0,
            (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0,
            info.st_size <= maximumBytes else { throw VaultMacCompanionError.diskFailure }
        return try readFD(fd, count: Int(info.st_size), offset: 0)
        #else
        throw VaultMacCompanionError.diskFailure
        #endif
    }
    static func readRange(_ url: URL, offset: UInt64, length: Int, expectedFileBytes: UInt64) throws -> Data {
        try rejectSymlink(url)
        #if canImport(Darwin)
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW); guard fd >= 0 else { throw VaultMacCompanionError.diskFailure }
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
        try rejectSymlink(url); #if canImport(Darwin)
        guard unlink(url.path) == 0 else { throw VaultMacCompanionError.diskFailure }
        #else
        throw VaultMacCompanionError.diskFailure
        #endif
    }
    static func removeTree(_ url: URL) throws {
        #if canImport(Darwin)
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw VaultMacCompanionError.diskFailure
        }
        let kind = info.st_mode & S_IFMT
        if kind == S_IFLNK || kind == S_IFREG {
            guard unlink(url.path) == 0 else { throw VaultMacCompanionError.diskFailure }
            try syncDirectory(url.deletingLastPathComponent())
            return
        }
        guard kind == S_IFDIR else { throw VaultMacCompanionError.diskFailure }
        for child in try FileManager.default.contentsOfDirectory(at: url,
            includingPropertiesForKeys: nil, options: []) {
            try removeTree(child)
        }
        guard rmdir(url.path) == 0 else { throw VaultMacCompanionError.diskFailure }
        try syncDirectory(url.deletingLastPathComponent())
        #else
        throw VaultMacCompanionError.diskFailure
        #endif
    }
    static func syncDirectory(_ url: URL) throws {
        #if canImport(Darwin)
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw VaultMacCompanionError.diskFailure }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw VaultMacCompanionError.diskFailure }
        #endif
    }
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

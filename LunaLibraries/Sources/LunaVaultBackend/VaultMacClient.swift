import CryptoKit
import Foundation
import LunaVaultCrypto
import LunaVaultModels
import LunaVaultStorage
import os

/// Wire-client diagnostics. Logs carry operations, revisions, statuses,
/// byte counts, and endpoint hosts — never key material or ciphertext.
/// Capture on device with:
///   log stream --level debug --predicate 'subsystem == "com.hsanabria.luna.vault"'
let vaultMacClientLog = os.Logger(subsystem: "com.hsanabria.luna.vault", category: "mac-client")

#if canImport(Network)
import Network

public final class VaultMacNWFrameChannel: VaultMacFrameChannel, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.hsanabria.luna.vault.mac-channel")
    public init(connection: NWConnection) { self.connection = connection }
    public func start() { connection.start(queue: queue) }
    public func startAndWaitUntilReady() async throws {
        let gate = VaultMacNWReadyGate()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: gate.finish(.success(()))
                    case .failed(let error): gate.finish(.failure(error))
                    case .cancelled: gate.finish(.failure(VaultMacProtocolError.unavailable))
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
        }, onCancel: { connection.cancel() })
    }
    public func send(_ frame: Data) async throws {
        guard frame.count > 0, frame.count <= VaultMacProtocol.maximumFrameBytes + 1024 else { throw VaultMacProtocolError.frameTooLarge }
        var size = UInt32(frame.count).bigEndian
        var data = Data(bytes: &size, count: 4); data.append(frame)
        let _: Void = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        }, onCancel: {
            connection.cancel()
        })
    }
    public func receive() async throws -> Data {
        let header = try await receiveExactly(4)
        let size = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard size > 0, size <= UInt32(VaultMacProtocol.maximumFrameBytes + 1024) else { throw VaultMacProtocolError.frameTooLarge }
        return try await receiveExactly(Int(size))
    }
    public func close() { connection.cancel() }
    private func receiveExactly(_ count: Int) async throws -> Data {
        var result = Data(); result.reserveCapacity(count)
        while result.count < count {
            let remaining = count - result.count
            let piece: Data = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, complete, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let data, !data.isEmpty { continuation.resume(returning: data) }
                        else if complete { continuation.resume(throwing: VaultMacProtocolError.unavailable) }
                        else { continuation.resume(throwing: VaultMacProtocolError.invalidFrame) }
                    }
                }
            }, onCancel: {
                connection.cancel()
            })
            result.append(piece)
        }
        return result
    }
}

public struct VaultMacNWConnector: VaultMacFrameConnecting {
    public init() {}
    public func connect(to endpoint: VaultMacEndpoint) async throws -> VaultMacFrameChannel {
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host),
                                      port: NWEndpoint.Port(rawValue: endpoint.port)!, using: .tcp)
        let channel = VaultMacNWFrameChannel(connection: connection)
        try await channel.startAndWaitUntilReady()
        return channel
    }
}

public final class VaultMacBonjourBrowser: VaultMacDiscoveryBrowsing, @unchecked Sendable {
    public struct Resolution: Equatable, Sendable {
        public let serverBinding: Data
        public let port: UInt16
        public init(serverBinding: Data, port: UInt16) throws {
            guard serverBinding.count == 32, port > 0 else {
                throw VaultMacProtocolError.invalidEndpoint
            }
            self.serverBinding = serverBinding
            self.port = port
        }
    }
    public typealias ResolutionResolver = @Sendable (String) -> Resolution?
    private let resolver: ResolutionResolver
    public init(resolutionResolver: @escaping ResolutionResolver) {
        self.resolver = resolutionResolver
    }
    public func records() -> AsyncThrowingStream<VaultMacDiscoveryRecord, Error> {
        AsyncThrowingStream { continuation in
            let browser = NWBrowser(for: .bonjour(type: VaultMacProtocol.serviceType, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [resolver] results, _ in
                for result in results {
                    guard case let .service(name, _, _, _) = result.endpoint,
                          let resolution = resolver(name),
                          let endpoint = try? VaultMacEndpoint(host: "\(name).local", port: resolution.port, reachability: .lanBonjour),
                          let record = try? VaultMacDiscoveryRecord(displayName: name, endpoint: endpoint,
                                                                    serverBinding: resolution.serverBinding) else { continue }
                    continuation.yield(record)
                }
            }
            browser.stateUpdateHandler = { state in
                if case let .failed(error) = state { continuation.finish(throwing: error) }
                if case .cancelled = state { continuation.finish() }
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: DispatchQueue(label: "com.hsanabria.luna.vault.mac-browser"))
        }
    }
}

private final class VaultMacNWReadyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    func install(_ continuation: CheckedContinuation<Void, Error>) {
        let immediate = lock.withLock { () -> Result<Void, Error>? in
            if let result { return result }
            self.continuation = continuation; return nil
        }
        if let immediate { continuation.resume(with: immediate) }
    }
    func finish(_ result: Result<Void, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard self.result == nil else { return nil }
            self.result = result
            let value = self.continuation; self.continuation = nil; return value
        }
        continuation?.resume(with: result)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
#endif

public actor VaultMacSessionClient {
    private let channel: VaultMacFrameChannel
    private let credential: VaultMacPairingCredential
    private let identityConfirmer: VaultMacServerIdentityConfirming
    private let random: VaultRandomBytesGenerating
    private let now: @Sendable () -> Date
    private var sender: VaultMacSendSequence?
    private var receiver: VaultMacReplayGuard?
    private var requestLockHeld = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    public init(channel: VaultMacFrameChannel, credential: VaultMacPairingCredential,
                identityConfirmer: VaultMacServerIdentityConfirming,
                random: VaultRandomBytesGenerating = SystemVaultRandomBytes(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.channel = channel; self.credential = credential
        self.identityConfirmer = identityConfirmer; self.random = random; self.now = now
    }

    public func authenticate() async throws {
        guard sender == nil, receiver == nil, credential.revokedAt == nil else { throw VaultMacProtocolError.revoked }
        let bytes = try await channel.receive()
        let message = try JSONDecoder().decode(VaultMacHandshakeMessage.self, from: bytes)
        guard message.kind == .challenge, let challenge = message.challenge,
              challenge.serverBinding == credential.serverBinding,
              challenge.endpointBinding == credential.endpointBinding else { throw VaultMacProtocolError.authenticationFailed }
        guard let confirmation = try await identityConfirmer.confirm(
                fingerprint: credential.fingerprint,
                endpointBinding: credential.endpointBinding),
              confirmation.fingerprint == credential.fingerprint,
              confirmation.endpointBinding == credential.endpointBinding else {
            throw VaultMacProtocolError.unconfirmedServerIdentity
        }
        let response = try VaultMacSessionResponse.make(challenge: challenge, credential: credential,
            clientNonce: random.bytes(count: 32), now: now())
        try await channel.send(JSONEncoder().encode(VaultMacHandshakeMessage(kind: .response, response: response)))
        let accepted = try JSONDecoder().decode(VaultMacHandshakeMessage.self, from: try await channel.receive())
        guard accepted.kind == .accepted, let acceptance = accepted.acceptance else {
            throw VaultMacProtocolError.authenticationFailed
        }
        try acceptance.verify(challenge: challenge, response: response,
                              credential: credential, now: now())
        let keys = try VaultMacSessionKeys(challenge: challenge, response: response,
                                           credential: credential, now: now())
        sender = VaultMacSendSequence(key: keys.requestKey, sessionID: challenge.sessionID, direction: .request)
        receiver = VaultMacReplayGuard(key: keys.responseKey, sessionID: challenge.sessionID, direction: .response)
    }

    public func request(_ request: VaultMacRequest) async throws -> VaultMacResponse {
        guard let sender, let receiver else { throw VaultMacProtocolError.authenticationFailed }
        await acquireRequestLock()
        defer { releaseRequestLock() }
        let frame = try sender.seal(JSONEncoder().encode(try request.validated()))
        try await channel.send(JSONEncoder().encode(frame))
        let responseFrame = try JSONDecoder().decode(VaultMacAuthenticatedFrame.self, from: try await channel.receive())
        return try JSONDecoder().decode(VaultMacResponse.self, from: receiver.open(responseFrame))
    }

    public func close() { channel.close() }

    /// `request` awaits twice on the shared frame channel (send, then
    /// receive), and an actor lets other calls interleave across those
    /// suspension points. A second `request` racing in would send its own
    /// frame while the first is still waiting on the reply, so a channel
    /// read could return bytes meant for the other call and corrupt
    /// framing. This lock keeps exactly one request in flight at a time.
    private func acquireRequestLock() async {
        if !requestLockHeld {
            requestLockHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    private func releaseRequestLock() {
        guard !requestWaiters.isEmpty else {
            requestLockHeld = false
            return
        }
        // Hand the lock directly to the next waiter; `requestLockHeld` stays
        // true throughout the handoff.
        requestWaiters.removeFirst().resume()
    }
}

public struct VaultMacClientTimeouts: Equatable, Sendable {
    public let connect: TimeInterval
    public let authenticate: TimeInterval
    public let request: TimeInterval
    public init(connect: TimeInterval = 10, authenticate: TimeInterval = 10,
                request: TimeInterval = 60) {
        self.connect = Self.clamp(connect, lower: 1, upper: 30, fallback: 10)
        self.authenticate = Self.clamp(authenticate, lower: 1, upper: 30, fallback: 10)
        self.request = Self.clamp(request, lower: 1, upper: 300, fallback: 60)
    }
    private static func clamp(_ value: TimeInterval, lower: TimeInterval,
                              upper: TimeInterval, fallback: TimeInterval) -> TimeInterval {
        value.isFinite ? min(max(value, lower), upper) : fallback
    }
}

public struct VaultMacPendingUpload: Codable, Equatable, Sendable {
    public let objectID: VaultObjectID
    public let revision: VaultRevision
    public let expectedRevision: UUID?
    public let totalCiphertextBytes: UInt64
    public let ciphertextDigest: Data
    /// Chunks `0..<acknowledgedChunkCount` already received a `.partial` or
    /// `.accepted` response from the server for this exact revision. A
    /// resumed upload skips re-sending their bodies.
    public var acknowledgedChunkCount: UInt32
    public init(objectID: VaultObjectID, revision: VaultRevision,
                expectedRevision: UUID?, totalCiphertextBytes: UInt64,
                ciphertextDigest: Data, acknowledgedChunkCount: UInt32 = 0) throws {
        guard revision.objectID == objectID, totalCiphertextBytes > 0,
              totalCiphertextBytes <= VaultMacProtocol.maximumObjectBytes,
              ciphertextDigest.count == 32 else { throw VaultMacProtocolError.invalidRequest }
        self.objectID = objectID; self.revision = revision
        self.expectedRevision = expectedRevision
        self.totalCiphertextBytes = totalCiphertextBytes
        self.ciphertextDigest = ciphertextDigest
        self.acknowledgedChunkCount = acknowledgedChunkCount
    }
    private enum CodingKeys: String, CodingKey {
        case objectID, revision, expectedRevision, totalCiphertextBytes
        case ciphertextDigest, acknowledgedChunkCount
    }
    // A record persisted before this field existed has no
    // `acknowledgedChunkCount` key; decode it as "nothing acknowledged yet"
    // rather than failing the whole pending-uploads file.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        objectID = try container.decode(VaultObjectID.self, forKey: .objectID)
        revision = try container.decode(VaultRevision.self, forKey: .revision)
        expectedRevision = try container.decodeIfPresent(UUID.self, forKey: .expectedRevision)
        totalCiphertextBytes = try container.decode(UInt64.self, forKey: .totalCiphertextBytes)
        ciphertextDigest = try container.decode(Data.self, forKey: .ciphertextDigest)
        acknowledgedChunkCount = try container.decodeIfPresent(
            UInt32.self, forKey: .acknowledgedChunkCount) ?? 0
    }
}

public protocol VaultMacUploadStateStoring: Sendable {
    func pendingUpload(for objectID: VaultObjectID) async throws -> VaultMacPendingUpload?
    func savePendingUpload(_ upload: VaultMacPendingUpload) async throws
    func removePendingUpload(for objectID: VaultObjectID) async throws
}

public actor VaultMacFileUploadStateStore: VaultMacUploadStateStoring {
    public static let shared = VaultMacFileUploadStateStore(fileURL: {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("LunaVault", isDirectory: true)
            .appendingPathComponent("mac-pending-uploads.json")
    }())
    private let fileURL: URL
    private var loaded = false
    private var uploads: [String: VaultMacPendingUpload] = [:]
    public init(fileURL: URL) { self.fileURL = fileURL }
    public func pendingUpload(for objectID: VaultObjectID) throws -> VaultMacPendingUpload? {
        try loadIfNeeded(); return uploads[objectID.rawValue.uuidString]
    }
    public func savePendingUpload(_ upload: VaultMacPendingUpload) throws {
        try loadIfNeeded()
        guard uploads.count < 1_024 || uploads[upload.objectID.rawValue.uuidString] != nil else {
            throw VaultMacProtocolError.unavailable
        }
        uploads[upload.objectID.rawValue.uuidString] = upload; try persist()
    }
    public func removePendingUpload(for objectID: VaultObjectID) throws {
        try loadIfNeeded()
        if uploads.removeValue(forKey: objectID.rawValue.uuidString) != nil { try persist() }
    }
    private func loadIfNeeded() throws {
        guard !loaded else { return }; loaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard data.count <= 1_048_576 else { throw VaultMacProtocolError.invalidFrame }
        let decoded = try JSONDecoder().decode([String: VaultMacPendingUpload].self, from: data)
        guard decoded.count <= 1_024,
              decoded.allSatisfy({ key, upload in
                  key == upload.objectID.rawValue.uuidString
              }) else { throw VaultMacProtocolError.invalidFrame }
        uploads = decoded
    }
    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(uploads)
        guard data.count <= 1_048_576 else { throw VaultMacProtocolError.frameTooLarge }
        try data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

public actor VaultMacRemoteBackend: VaultStreamingBackendTransport {
    /// `ciphertext(for:)` materializes its whole result in memory. A Mac
    /// object can be up to 100 GiB; capping this path at artifact scale
    /// keeps it from jetsamming the process. Anything larger must go
    /// through the streaming `payloadFile(for:)` path instead.
    private static let maximumInMemoryCiphertextBytes: UInt64 = 16 * 1024 * 1024

    private let endpoint: VaultMacEndpoint
    private let credential: VaultMacPairingCredential
    private let connector: VaultMacFrameConnecting
    private let identityConfirmer: VaultMacServerIdentityConfirming
    private let random: VaultRandomBytesGenerating
    private let timeouts: VaultMacClientTimeouts
    private let uploadStateStore: any VaultMacUploadStateStoring
    private var revisions: [VaultObjectID: VaultRevision] = [:]

    public init(endpoint: VaultMacEndpoint, credential: VaultMacPairingCredential,
                connector: VaultMacFrameConnecting, identityConfirmer: VaultMacServerIdentityConfirming,
                random: VaultRandomBytesGenerating = SystemVaultRandomBytes(),
                timeouts: VaultMacClientTimeouts = VaultMacClientTimeouts(),
                uploadStateStore: any VaultMacUploadStateStoring = VaultMacFileUploadStateStore.shared) throws {
        _ = VaultProtectedDownloadTemporarySweep.sweep()
        guard endpoint.binding == credential.endpointBinding else { throw VaultMacProtocolError.invalidEndpoint }
        self.endpoint = endpoint; self.credential = credential; self.connector = connector
        self.identityConfirmer = identityConfirmer; self.random = random; self.timeouts = timeouts
        self.uploadStateStore = uploadStateStore
    }

    /// Runs the resumable chunked-upload state machine shared by the
    /// byte-array and file-backed put paths. It resolves or replaces the
    /// pending record, skips chunks the server already acknowledged, and
    /// requires `.accepted` on the terminal chunk before the caller may
    /// treat the object as durably committed — a terminal `.partial` is a
    /// retryable failure, so the pending record and any staged local
    /// payload must both survive it.
    private func performChunkedUpload(
        id: VaultObjectID, byteCount: UInt64, digest: Data,
        revision: VaultRevision, expectedRevision: UUID?,
        kind: VaultRemoteObjectKind?, generation: String?, logPrefix: String,
        verifyUnchanged: (() throws -> Bool)? = nil,
        readChunk: (Range<Int>) throws -> Data
    ) async throws {
        let plan = try VaultMacChunkPlan(byteCount: byteCount)
        let existingPending = try await uploadStateStore.pendingUpload(for: id)
        var upload: VaultMacPendingUpload
        if let existingPending, existingPending.totalCiphertextBytes == byteCount,
           existingPending.ciphertextDigest == digest {
            upload = existingPending
        } else {
            if existingPending != nil {
                // The retained record no longer matches this content: it is
                // stale, not merely incomplete. Drop it and start a fresh
                // upload rather than permanently blocking the object on a
                // digest that can never match again.
                vaultMacClientLog.error("\(logPrefix, privacy: .public) pending record is stale; starting a fresh upload. object=\(id.rawValue.uuidString, privacy: .public)")
                try? await uploadStateStore.removePendingUpload(for: id)
            }
            upload = try VaultMacPendingUpload(objectID: id, revision: revision,
                expectedRevision: expectedRevision, totalCiphertextBytes: byteCount,
                ciphertextDigest: digest)
            try await uploadStateStore.savePendingUpload(upload)
        }
        let client = try await makeClient()
        defer { Task { await client.close() } }
        // Never skip the final chunk: an earlier attempt's terminal response
        // for it may have been `.partial`, and only a fresh response tells
        // us whether the server has since committed the object.
        let startIndex = min(upload.acknowledgedChunkCount, plan.totalChunks - 1)
        vaultMacClientLog.info("\(logPrefix, privacy: .public) start. object=\(id.rawValue.uuidString, privacy: .public) bytes=\(byteCount, privacy: .public) chunks=\(plan.totalChunks, privacy: .public) resumeFrom=\(startIndex, privacy: .public)")
        var finalStatus: VaultMacResponseStatus = .partial
        for index in startIndex..<plan.totalChunks {
            let range = try plan.range(for: index)
            let chunk = try readChunk(range)
            let request = VaultMacRequest(operation: .putChunk, objectID: id, revision: upload.revision,
                expectedRevision: upload.expectedRevision, chunkIndex: index, totalChunks: plan.totalChunks,
                totalCiphertextBytes: byteCount,
                idempotencyKey: VaultMacRequestFactory.idempotencyKey(objectID: id,
                    revision: upload.revision.revision, chunkIndex: index), ciphertext: chunk,
                objectKind: kind, payloadGeneration: generation)
            let response = try await timedRequest(request, client: client,
                timeout: requestTimeout(forCiphertextBytes: chunk.count))
            guard response.status == .partial || response.status == .accepted else {
                vaultMacClientLog.error("\(logPrefix, privacy: .public) rejected. object=\(id.rawValue.uuidString, privacy: .public) chunk=\(index, privacy: .public)/\(plan.totalChunks, privacy: .public) status=\(String(describing: response.status), privacy: .public)")
                if response.status == .conflict {
                    // The server's conflict response carries its current
                    // revision. Refresh the cache from it so the next
                    // attempt (from `put`) derives the right expected
                    // revision instead of repeating the same stale compare.
                    if let revision = response.revision { revisions[id] = revision }
                    try? await uploadStateStore.removePendingUpload(for: id)
                }
                throw VaultMacProtocolError.conflictingRevision
            }
            finalStatus = response.status
            upload.acknowledgedChunkCount = index + 1
            try await uploadStateStore.savePendingUpload(upload)
        }
        if let verifyUnchanged {
            guard try verifyUnchanged() else {
                vaultMacClientLog.error("\(logPrefix, privacy: .public) aborted: source changed mid-upload. object=\(id.rawValue.uuidString, privacy: .public)")
                throw VaultMacProtocolError.conflictingRevision
            }
        }
        guard finalStatus == .accepted else {
            vaultMacClientLog.error("\(logPrefix, privacy: .public) not committed: final chunk returned \(String(describing: finalStatus), privacy: .public). object=\(id.rawValue.uuidString, privacy: .public)")
            throw VaultMacProtocolError.unavailable
        }
        vaultMacClientLog.info("\(logPrefix, privacy: .public) complete. object=\(id.rawValue.uuidString, privacy: .public) bytes=\(byteCount, privacy: .public)")
        revisions[id] = upload.revision
        try await uploadStateStore.removePendingUpload(for: id)
    }

    private func putCiphertext(_ ciphertext: Data, for id: VaultObjectID,
                               revision: VaultRevision,
                               expectedRevision: UUID?, kind: VaultRemoteObjectKind? = nil,
                               generation: String? = nil) async throws {
        let digest = Data(SHA256.hash(data: ciphertext))
        try await performChunkedUpload(id: id, byteCount: UInt64(ciphertext.count), digest: digest,
            revision: revision, expectedRevision: expectedRevision, kind: kind, generation: generation,
            logPrefix: "Upload") { range in Data(ciphertext[range]) }
    }

    private func putCiphertextFile(_ payload: VaultVerifiedCiphertextFile, byteCount: UInt64,
                                   for id: VaultObjectID, revision: VaultRevision,
                                   expectedRevision: UUID?, kind: VaultRemoteObjectKind? = nil,
                                   generation: String? = nil) async throws {
        guard payload.ciphertextByteCount == byteCount else {
            throw VaultMacProtocolError.conflictingRevision
        }
        // The verified payload retains the descriptor that was authenticated
        // by VaultAuthenticatedCiphertextFile. Both digest passes and every
        // chunk read below therefore refer to one immutable inode, never a
        // reopened pathname.
        let digest = try payload.digestBytes()
        try await performChunkedUpload(id: id, byteCount: byteCount, digest: digest,
            revision: revision, expectedRevision: expectedRevision, kind: kind, generation: generation,
            logPrefix: "File upload",
            verifyUnchanged: { try payload.digestBytes() == digest }
        ) { range in try payload.read(offset: UInt64(range.lowerBound), count: range.count) }
    }

    public func ciphertext(for id: VaultObjectID) async throws -> Data? {
        let client = try await makeClient(); defer { Task { await client.close() } }
        let stat = try await timedRequest(VaultMacRequest(operation: .stat,
            objectID: id, idempotencyKey: UUID().uuidString), client: client)
        if stat.status == .notFound {
            if let revision = stat.revision { revisions[id] = revision }
            return nil
        }
        guard stat.status == .accepted, let total = stat.totalCiphertextBytes,
              let statRevision = stat.revision, total > 0,
              total <= VaultMacProtocol.maximumObjectBytes else { throw VaultMacProtocolError.invalidFrame }
        // This path buffers the whole object in memory. A Mac object can be
        // up to 100 GiB; only an artifact-scale download may use it. Anything
        // larger must stream through `payloadFile(for:)` instead.
        guard total <= Self.maximumInMemoryCiphertextBytes else { throw VaultMacProtocolError.objectTooLarge }
        revisions[id] = statRevision
        var output = Data(); if total <= UInt64(Int.max) { output.reserveCapacity(Int(total)) }
        var offset: UInt64 = 0
        while offset < total {
            let length = min(UInt64(VaultMacProtocol.maximumTransferBytes), total - offset)
            let response = try await timedRequest(VaultMacRequest(operation: .readRange, objectID: id,
                offset: offset, length: length, idempotencyKey: UUID().uuidString), client: client)
            guard response.status == .accepted, let bytes = response.ciphertext,
                  response.revision == statRevision,
                  UInt64(bytes.count) == length else {
                vaultMacClientLog.error("Range read failed. object=\(id.rawValue.uuidString, privacy: .public) offset=\(offset, privacy: .public) status=\(String(describing: response.status), privacy: .public)")
                throw VaultMacProtocolError.conflictingRevision
            }
            output.append(bytes); offset += length
        }
        vaultMacClientLog.info("Download complete. object=\(id.rawValue.uuidString, privacy: .public) bytes=\(total, privacy: .public)")
        return output
    }

    public func removeCiphertext(for id: VaultObjectID) async throws {
        guard let current = try await remoteRevision(for: id) else { return }
        let tombstone = VaultRevision(objectID: id,
            logicalTime: try nextLogicalTime(after: current.logicalTime), deviceID: "iphone")
        let client = try await makeClient(); defer { Task { await client.close() } }
        let response = try await timedRequest(VaultMacRequest(operation: .delete, objectID: id,
            revision: tombstone, expectedRevision: current.revision, idempotencyKey: UUID().uuidString), client: client)
        guard response.status == .accepted || response.status == .notFound else {
            vaultMacClientLog.error("Delete rejected. object=\(id.rawValue.uuidString, privacy: .public) status=\(String(describing: response.status), privacy: .public)")
            throw VaultMacProtocolError.conflictingRevision
        }
        vaultMacClientLog.info("Delete accepted. object=\(id.rawValue.uuidString, privacy: .public)")
        revisions[id] = tombstone
    }

    private func remoteRevision(for id: VaultObjectID) async throws -> VaultRevision? {
        if let revision = revisions[id] { return revision }
        let client = try await makeClient(); defer { Task { await client.close() } }
        let stat = try await timedRequest(VaultMacRequest(operation: .stat,
            objectID: id, idempotencyKey: UUID().uuidString), client: client)
        switch stat.status {
        case .notFound:
            // A deleted object answers .notFound but still carries its
            // tombstone revision; a replacement put must present it as the
            // expected revision or the server's revision guard conflicts.
            if let revision = stat.revision {
                revisions[id] = revision
                return revision
            }
            return nil
        case .accepted:
            guard let revision = stat.revision else { throw VaultMacProtocolError.invalidFrame }
            revisions[id] = revision
            return revision
        default:
            // Any other status (`.invalid`, `.failed`, …) is not a safe
            // "object absent" answer — silently returning nil here would
            // let a caller proceed as if the object had no remote history.
            throw VaultMacProtocolError.invalidFrame
        }
    }

    private func makeClient() async throws -> VaultMacSessionClient {
        let started = Date()
        let channel: any VaultMacFrameChannel
        do {
            channel = try await vaultMacWithTimeout(seconds: timeouts.connect) {
                try await self.connector.connect(to: self.endpoint)
            }
        } catch {
            vaultMacClientLog.error("Connect to \(self.endpoint.host, privacy: .public):\(self.endpoint.port, privacy: .public) (\(self.endpoint.reachability.rawValue, privacy: .public)) failed after \(Int(Date().timeIntervalSince(started) * 1_000), privacy: .public)ms: \(String(describing: error), privacy: .public)")
            throw error
        }
        let client = VaultMacSessionClient(channel: channel,
            credential: credential, identityConfirmer: identityConfirmer, random: random)
        do {
            try await vaultMacWithTimeout(seconds: timeouts.authenticate) {
                try await client.authenticate()
            }
            vaultMacClientLog.info("Authenticated session with \(self.endpoint.host, privacy: .public):\(self.endpoint.port, privacy: .public) in \(Int(Date().timeIntervalSince(started) * 1_000), privacy: .public)ms")
            return client
        } catch {
            vaultMacClientLog.error("Session authentication with \(self.endpoint.host, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            await client.close(); throw error
        }
    }

    private func timedRequest(_ request: VaultMacRequest, client: VaultMacSessionClient,
                              timeout: TimeInterval? = nil) async throws -> VaultMacResponse {
        do {
            return try await vaultMacWithTimeout(seconds: timeout ?? timeouts.request) {
                try await client.request(request)
            }
        } catch {
            vaultMacClientLog.error("Request failed. op=\(request.operation.rawValue, privacy: .public) object=\(request.objectID.rawValue.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// A flat request timeout implies a fixed minimum transfer speed for the
    /// largest chunk it must carry — at the default 60s/4 MiB that is
    /// ~70 KB/s, which fails chunk 0 outright on a slow relay path. Scale the
    /// wait for a `putChunk` request by the chunk's own byte count instead;
    /// every other request keeps the configured flat timeout.
    private func requestTimeout(forCiphertextBytes byteCount: Int) -> TimeInterval {
        guard byteCount > 0 else { return timeouts.request }
        let scale = Double(byteCount) / Double(VaultMacProtocol.maximumTransferBytes)
        return max(timeouts.request, timeouts.request * scale)
    }

    private func nextLogicalTime(after previous: Int64?) throws -> Int64 {
        let milliseconds = Date().timeIntervalSince1970 * 1_000
        let wallClock = milliseconds.isFinite && milliseconds < Double(Int64.max)
            ? Int64(milliseconds) : Int64.max
        guard let previous else { return wallClock }
        let (successor, overflow) = previous.addingReportingOverflow(1)
        guard !overflow else { throw VaultMacProtocolError.sequenceOverflow }
        return max(successor, wallClock)
    }
}

// The Mac wire client also participates in the common Stage 4 backend
// scheduler. These adapters preserve the protocol's authenticated-payload
// boundary while retaining the lower-level chunk API used by companion tests.
extension VaultMacRemoteBackend {
    public nonisolated var identity: VaultBackendIdentity {
        VaultBackendIdentity(location: .mac, containerIdentifier: endpoint.binding,
                             vaultID: "default")
    }

    public nonisolated var capabilities: VaultBackendCapabilities {
        VaultBackendCapabilities(location: .mac, availability: .available,
            supportsAtomicWrites: true, supportsRangeReads: true,
            supportsEviction: false, requiresClientSideEncryption: true)
    }

    public nonisolated var currentAvailability: VaultBackendAvailability { .available }

    public func put(_ payload: VaultVerifiedCiphertext,
                    expectedRevision: UUID?) async throws -> VaultBackendWriteOutcome {
        guard payload.vaultID == identity.vaultID else {
            throw VaultBackendError.corruptPayload
        }
        do {
            let identity = payload.identity
            let current = try await remoteRevision(for: identity.objectID)
            let discoveredExpectedRevision = expectedRevision ?? current?.revision
            let revision = VaultRevision(objectID: identity.objectID, revision: identity.revision,
                logicalTime: try nextLogicalTime(after: current?.logicalTime), deviceID: "iphone")
            try await putCiphertext(try payload.encodedFileData(), for: identity.objectID,
                                    revision: revision, expectedRevision: discoveredExpectedRevision,
                                    kind: identity.kind, generation: identity.generation)
            return .current
        } catch { throw Self.mapPutError(error) }
    }

    public func put(_ payload: VaultVerifiedCiphertextFile,
                    expectedRevision: UUID?) async throws -> VaultBackendWriteOutcome {
        guard payload.vaultID == identity.vaultID else { throw VaultBackendError.corruptPayload }
        do {
            let current = try await self.remoteRevision(for: payload.identity.objectID)
            let discoveredExpectedRevision = expectedRevision ?? current?.revision
            let revision = VaultRevision(objectID: payload.identity.objectID,
                revision: payload.identity.revision,
                logicalTime: try nextLogicalTime(after: current?.logicalTime), deviceID: "iphone")
            try await putCiphertextFile(payload,
                byteCount: payload.ciphertextByteCount, for: payload.identity.objectID,
                revision: revision, expectedRevision: discoveredExpectedRevision,
                kind: payload.identity.kind, generation: payload.identity.generation)
            return .current
        } catch { throw Self.mapPutError(error) }
    }

    /// Maps a wire-level `VaultMacProtocolError` onto the transport-neutral
    /// `VaultBackendError` contract every caller of `put` switches on. A
    /// cancelled operation is never turned into a backend error — the caller
    /// must see the real `CancellationError` rather than a mapped `.io`.
    private static func mapPutError(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if error is VaultBackendError { return error }
        guard let protocolError = error as? VaultMacProtocolError else { return VaultBackendError.io }
        switch protocolError {
        case .conflictingRevision: return VaultBackendError.conflict
        case .expired, .unavailable: return VaultBackendError.unavailable
        default: return VaultBackendError.io
        }
    }

    public func payload(for identity: VaultRemoteObjectIdentity) async throws
        -> VaultAuthenticatedCiphertext? {
        guard let bytes = try await ciphertext(for: identity.objectID) else { return nil }
        do {
            return try VaultAuthenticatedCiphertext.decodeAndValidate(
                bytes, expected: identity, vaultID: self.identity.vaultID)
        } catch {
            throw VaultBackendError.corruptPayload
        }
    }

    public func payloadFile(for identity: VaultRemoteObjectIdentity) async throws
        -> VaultAuthenticatedCiphertextFile? {
        let client = try await makeClient(); defer { Task { await client.close() } }
        let stat = try await timedRequest(VaultMacRequest(operation: .stat,
            objectID: identity.objectID, idempotencyKey: UUID().uuidString), client: client)
        guard stat.status == .accepted else {
            if stat.status == .notFound { return nil }
            throw VaultBackendError.io
        }
        guard let total = stat.totalCiphertextBytes, total > 0,
              total <= VaultMacProtocol.maximumObjectBytes,
              stat.revision?.revision == identity.revision,
              stat.objectKind == identity.kind,
              stat.payloadGeneration == identity.generation else {
            throw VaultBackendError.staleVersion
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("luna-vault-mac-\(UUID().uuidString).lvf")
        var keepTemporary = false
        defer {
            if !keepTemporary { try? VaultSecureFileAccess.removeRegularFile(at: temporary) }
        }
        // Establish the protected inode before any ciphertext arrives from
        // the Mac. The transport never writes into an unprotected temporary.
        let created = try VaultSecureFileAccess.createEmptyFile(at: temporary)
        try created.close()
        let protection = SystemVaultFileProtectionApplier()
        try protection.apply(to: temporary)
        guard (try? protection.hasRequiredProtection(at: temporary)) == true else {
            throw VaultBackendError.permissionDenied
        }
        do {
            let output = try VaultSecureFileAccess.openForWriting(at: temporary)
            defer { try? output.close() }
            var offset: UInt64 = 0
            while offset < total {
                let length = min(UInt64(VaultMacProtocol.maximumTransferBytes), total - offset)
                let response = try await timedRequest(VaultMacRequest(operation: .readRange,
                    objectID: identity.objectID, offset: offset, length: length,
                    idempotencyKey: UUID().uuidString), client: client)
                guard response.status == .accepted, response.revision?.revision == identity.revision,
                      response.objectKind == identity.kind,
                      response.payloadGeneration == identity.generation,
                      let bytes = response.ciphertext, UInt64(bytes.count) == length else {
                    throw VaultBackendError.conflict
                }
                try output.write(contentsOf: bytes); offset += length
            }
            try output.synchronize()
            let result = try VaultAuthenticatedCiphertextFile(fileURL: temporary,
                expectedIdentity: identity, vaultID: self.identity.vaultID, ownsFile: true)
            keepTemporary = true
            vaultMacClientLog.info("Streamed download complete. object=\(identity.objectID.rawValue.uuidString, privacy: .public) bytes=\(total, privacy: .public)")
            return result
        } catch {
            if let error = error as? VaultBackendError { throw error }
            throw VaultBackendError.corruptPayload
        }
    }

    public func remove(_ identity: VaultRemoteObjectIdentity,
                       expectedRevision: UUID?) async throws {
        if let expectedRevision, expectedRevision != identity.revision {
            throw VaultBackendError.staleVersion
        }
        // `expectedRevision == identity.revision` only checks the caller's
        // own claim against itself. The remote's actual current revision
        // must also match `identity.revision`, or a delete queued against an
        // older revision could tombstone data a newer write already landed.
        guard let current = try await remoteRevision(for: identity.objectID) else { return }
        guard current.revision == identity.revision else {
            throw VaultBackendError.staleVersion
        }
        try await removeCiphertext(for: identity.objectID)
    }

    public func state(for identity: VaultRemoteObjectIdentity) async throws
        -> VaultRemoteObjectState {
        let client = try await makeClient()
        defer { Task { await client.close() } }
        let stat = try await timedRequest(VaultMacRequest(operation: .stat,
            objectID: identity.objectID, idempotencyKey: UUID().uuidString), client: client)
        guard stat.status == .accepted else {
            return stat.status == .notFound ? .missing : .failed
        }
        guard let revision = stat.revision else { return .conflicted }
        guard revision.revision == identity.revision else { return .conflicted }
        guard stat.objectKind == identity.kind,
              stat.payloadGeneration == identity.generation else { return .conflicted }
        guard stat.totalCiphertextBytes.map({ $0 > 0 && $0 <= VaultMacProtocol.maximumObjectBytes }) == true else {
            return .failed
        }
        return .current
    }
}

private func vaultMacWithTimeout<T: Sendable>(seconds: TimeInterval,
                                               operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw VaultMacProtocolError.expired
        }
        guard let result = try await group.next() else { throw VaultMacProtocolError.unavailable }
        group.cancelAll(); return result
    }
}

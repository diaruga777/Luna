import CryptoKit
import Foundation
import LunaVaultCrypto
import LunaVaultModels

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
        let frame = try sender.seal(JSONEncoder().encode(try request.validated()))
        try await channel.send(JSONEncoder().encode(frame))
        let responseFrame = try JSONDecoder().decode(VaultMacAuthenticatedFrame.self, from: try await channel.receive())
        return try JSONDecoder().decode(VaultMacResponse.self, from: receiver.open(responseFrame))
    }

    public func close() { channel.close() }
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
    public init(objectID: VaultObjectID, revision: VaultRevision,
                expectedRevision: UUID?, totalCiphertextBytes: UInt64,
                ciphertextDigest: Data) throws {
        guard revision.objectID == objectID, totalCiphertextBytes > 0,
              totalCiphertextBytes <= VaultMacProtocol.maximumObjectBytes,
              ciphertextDigest.count == 32 else { throw VaultMacProtocolError.invalidRequest }
        self.objectID = objectID; self.revision = revision
        self.expectedRevision = expectedRevision
        self.totalCiphertextBytes = totalCiphertextBytes
        self.ciphertextDigest = ciphertextDigest
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
        guard endpoint.binding == credential.endpointBinding else { throw VaultMacProtocolError.invalidEndpoint }
        self.endpoint = endpoint; self.credential = credential; self.connector = connector
        self.identityConfirmer = identityConfirmer; self.random = random; self.timeouts = timeouts
        self.uploadStateStore = uploadStateStore
    }

    public func putCiphertext(_ ciphertext: Data, for id: VaultObjectID) async throws {
        let previous = try await remoteRevision(for: id)
        let revision = VaultRevision(objectID: id,
            logicalTime: try nextLogicalTime(after: previous?.logicalTime), deviceID: "iphone")
        try await putCiphertext(ciphertext, for: id, revision: revision,
                                expectedRevision: previous?.revision)
    }

    /// Uploads an already-authenticated Vault payload while retaining its
    /// immutable remote identity.  The Stage 4 sync coordinator uses this
    /// path; the legacy raw-byte helper above remains convenient for the Mac
    /// protocol tests.
    private func putCiphertext(_ ciphertext: Data, for id: VaultObjectID,
                               revision: VaultRevision,
                               expectedRevision: UUID?) async throws {
        let plan = try VaultMacChunkPlan(byteCount: UInt64(ciphertext.count))
        let digest = Data(SHA256.hash(data: ciphertext))
        let pending = try await uploadStateStore.pendingUpload(for: id)
        let upload: VaultMacPendingUpload
        if let pending {
            guard pending.totalCiphertextBytes == UInt64(ciphertext.count),
                  pending.ciphertextDigest == digest else {
                throw VaultMacProtocolError.conflictingRevision
            }
            upload = pending
        } else {
            upload = try VaultMacPendingUpload(objectID: id, revision: revision,
                expectedRevision: expectedRevision, totalCiphertextBytes: UInt64(ciphertext.count),
                ciphertextDigest: digest)
            try await uploadStateStore.savePendingUpload(upload)
        }
        let client = try await makeClient()
        defer { Task { await client.close() } }
        for index in 0..<plan.totalChunks {
            let range = try plan.range(for: index)
            let request = VaultMacRequest(operation: .putChunk, objectID: id, revision: upload.revision,
                expectedRevision: upload.expectedRevision, chunkIndex: index, totalChunks: plan.totalChunks,
                totalCiphertextBytes: UInt64(ciphertext.count),
                idempotencyKey: VaultMacRequestFactory.idempotencyKey(objectID: id,
                    revision: upload.revision.revision, chunkIndex: index),
                ciphertext: Data(ciphertext[range]))
            let response = try await timedRequest(request, client: client)
            guard response.status == .partial || response.status == .accepted else {
                // A revision conflict means the durable pending revision can
                // never be accepted by this server state. Drop only that
                // stale marker; transient quota/unavailable errors remain
                // resumable with the same revision on the next attempt.
                if response.status == .conflict {
                    try? await uploadStateStore.removePendingUpload(for: id)
                }
                throw VaultMacProtocolError.conflictingRevision
            }
        }
        revisions[id] = upload.revision
        try await uploadStateStore.removePendingUpload(for: id)
    }

    private func putCiphertextFile(_ fileURL: URL, byteCount: UInt64,
                                   for id: VaultObjectID, revision: VaultRevision,
                                   expectedRevision: UUID?) async throws {
        let plan = try VaultMacChunkPlan(byteCount: byteCount)
        let digest = try SHA256.hashFile(at: fileURL, byteCount: byteCount)
        let pending = try await uploadStateStore.pendingUpload(for: id)
        let upload: VaultMacPendingUpload
        if let pending {
            guard pending.totalCiphertextBytes == byteCount,
                  pending.ciphertextDigest == digest else {
                throw VaultMacProtocolError.conflictingRevision
            }
            upload = pending
        } else {
            upload = try VaultMacPendingUpload(objectID: id, revision: revision,
                expectedRevision: expectedRevision, totalCiphertextBytes: byteCount,
                ciphertextDigest: digest)
            try await uploadStateStore.savePendingUpload(upload)
        }
        let client = try await makeClient()
        defer { Task { await client.close() } }
        for index in 0..<plan.totalChunks {
            let range = try plan.range(for: index)
            let chunk = try Self.readFile(fileURL, range: range)
            let request = VaultMacRequest(operation: .putChunk, objectID: id, revision: upload.revision,
                expectedRevision: upload.expectedRevision, chunkIndex: index, totalChunks: plan.totalChunks,
                totalCiphertextBytes: byteCount,
                idempotencyKey: VaultMacRequestFactory.idempotencyKey(objectID: id,
                    revision: upload.revision.revision, chunkIndex: index), ciphertext: chunk)
            let response = try await timedRequest(request, client: client)
            guard response.status == .partial || response.status == .accepted else {
                if response.status == .conflict { try? await uploadStateStore.removePendingUpload(for: id) }
                throw VaultMacProtocolError.conflictingRevision
            }
        }
        revisions[id] = upload.revision
        try await uploadStateStore.removePendingUpload(for: id)
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
        revisions[id] = statRevision
        var output = Data(); if total <= UInt64(Int.max) { output.reserveCapacity(Int(total)) }
        var offset: UInt64 = 0
        while offset < total {
            let length = min(UInt64(VaultMacProtocol.maximumTransferBytes), total - offset)
            let response = try await timedRequest(VaultMacRequest(operation: .readRange, objectID: id,
                offset: offset, length: length, idempotencyKey: UUID().uuidString), client: client)
            guard response.status == .accepted, let bytes = response.ciphertext,
                  response.revision == statRevision,
                  UInt64(bytes.count) == length else { throw VaultMacProtocolError.conflictingRevision }
            output.append(bytes); offset += length
        }
        return output
    }

    public func removeCiphertext(for id: VaultObjectID) async throws {
        guard let current = try await remoteRevision(for: id) else { return }
        let tombstone = VaultRevision(objectID: id,
            logicalTime: try nextLogicalTime(after: current.logicalTime), deviceID: "iphone")
        let client = try await makeClient(); defer { Task { await client.close() } }
        let response = try await timedRequest(VaultMacRequest(operation: .delete, objectID: id,
            revision: tombstone, expectedRevision: current.revision, idempotencyKey: UUID().uuidString), client: client)
        guard response.status == .accepted || response.status == .notFound else { throw VaultMacProtocolError.conflictingRevision }
        revisions[id] = tombstone
    }

    private func remoteRevision(for id: VaultObjectID) async throws -> VaultRevision? {
        if let revision = revisions[id] { return revision }
        let client = try await makeClient(); defer { Task { await client.close() } }
        let stat = try await timedRequest(VaultMacRequest(operation: .stat,
            objectID: id, idempotencyKey: UUID().uuidString), client: client)
        guard stat.status == .accepted || stat.status == .notFound,
              let revision = stat.revision else { return nil }
        revisions[id] = revision; return revision
    }

    private func makeClient() async throws -> VaultMacSessionClient {
        let channel = try await vaultMacWithTimeout(seconds: timeouts.connect) {
            try await self.connector.connect(to: self.endpoint)
        }
        let client = VaultMacSessionClient(channel: channel,
            credential: credential, identityConfirmer: identityConfirmer, random: random)
        do {
            try await vaultMacWithTimeout(seconds: timeouts.authenticate) {
                try await client.authenticate()
            }
            return client
        } catch {
            await client.close(); throw error
        }
    }

    private func timedRequest(_ request: VaultMacRequest,
                              client: VaultMacSessionClient) async throws -> VaultMacResponse {
        try await vaultMacWithTimeout(seconds: timeouts.request) {
            try await client.request(request)
        }
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
        let identity = payload.identity
        let logicalTime = Int64(Date().timeIntervalSince1970 * 1_000)
        let revision = VaultRevision(objectID: identity.objectID,
            revision: identity.revision, logicalTime: logicalTime, deviceID: "iphone")
        try await putCiphertext(try payload.encoded(), for: identity.objectID,
                                revision: revision, expectedRevision: expectedRevision)
        return .current
    }

    public func put(_ payload: VaultVerifiedCiphertextFile,
                    expectedRevision: UUID?) async throws -> VaultBackendWriteOutcome {
        guard payload.vaultID == identity.vaultID else { throw VaultBackendError.corruptPayload }
        let remoteRevision = VaultRevision(objectID: payload.identity.objectID,
            revision: payload.identity.revision,
            logicalTime: Int64(Date().timeIntervalSince1970 * 1_000), deviceID: "iphone")
        do {
            try await putCiphertextFile(payload.fileURL,
                byteCount: payload.ciphertextByteCount, for: payload.identity.objectID,
                revision: remoteRevision, expectedRevision: expectedRevision)
            return .current
        } catch let error as VaultBackendError { throw error }
        catch { throw VaultBackendError.io }
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
              stat.revision?.revision == identity.revision else {
            throw VaultBackendError.staleVersion
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("luna-vault-mac-\(UUID().uuidString).lvf")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw VaultBackendError.io
        }
        do {
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close() }
            var offset: UInt64 = 0
            while offset < total {
                let length = min(UInt64(VaultMacProtocol.maximumTransferBytes), total - offset)
                let response = try await timedRequest(VaultMacRequest(operation: .readRange,
                    objectID: identity.objectID, offset: offset, length: length,
                    idempotencyKey: UUID().uuidString), client: client)
                guard response.status == .accepted, response.revision?.revision == identity.revision,
                      let bytes = response.ciphertext, UInt64(bytes.count) == length else {
                    throw VaultBackendError.conflict
                }
                try output.write(contentsOf: bytes); offset += length
            }
            try output.synchronize()
            return try VaultAuthenticatedCiphertextFile(fileURL: temporary,
                expectedIdentity: identity, vaultID: self.identity.vaultID)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if let error = error as? VaultBackendError { throw error }
            throw VaultBackendError.corruptPayload
        }
    }

    public func remove(_ identity: VaultRemoteObjectIdentity,
                       expectedRevision: UUID?) async throws {
        if let expectedRevision, expectedRevision != identity.revision {
            throw VaultBackendError.staleVersion
        }
        try await removeCiphertext(for: identity.objectID)
    }

    public func state(for identity: VaultRemoteObjectIdentity) async throws
        -> VaultRemoteObjectState {
        guard let payload = try await payloadFile(for: identity) else { return .missing }
        return payload.identity == identity ? .current : .conflicted
    }

    private static func readFile(_ fileURL: URL, range: Range<Int>) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        guard let data = try handle.read(upToCount: range.count), data.count == range.count else {
            throw VaultMacProtocolError.invalidFrame
        }
        return data
    }
}

private extension SHA256 {
    static func hashFile(at url: URL, byteCount: UInt64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256(); var remaining = byteCount
        while remaining > 0 {
            guard let chunk = try handle.read(upToCount: Int(min(UInt64(1_048_576), remaining))),
                  !chunk.isEmpty else { throw VaultMacProtocolError.invalidFrame }
            hasher.update(data: chunk); remaining -= UInt64(chunk.count)
        }
        guard try handle.read(upToCount: 1)?.isEmpty != false else {
            throw VaultMacProtocolError.invalidFrame
        }
        return Data(hasher.finalize())
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

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
        channel.start()
        return channel
    }
}

public final class VaultMacBonjourBrowser: VaultMacDiscoveryBrowsing, @unchecked Sendable {
    public typealias BindingResolver = @Sendable (String) -> Data?
    private let resolver: BindingResolver
    private let port: UInt16
    /// Bonjour's service endpoint does not expose a TCP port through the
    /// lightweight record seam, so callers supply the port advertised by the
    /// companion. The default matches the CLI, while custom listeners can use
    /// their own port without silently connecting to 49,200.
    public init(bindingResolver: @escaping BindingResolver, port: UInt16 = 49_200) {
        self.resolver = bindingResolver
        self.port = port > 0 ? port : 49_200
    }
    public func records() -> AsyncThrowingStream<VaultMacDiscoveryRecord, Error> {
        AsyncThrowingStream { continuation in
            let advertisedPort = self.port
            let browser = NWBrowser(for: .bonjour(type: VaultMacProtocol.serviceType, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [resolver, advertisedPort] results, _ in
                for result in results {
                    guard case let .service(name, _, _, _) = result.endpoint,
                          let binding = resolver(name),
                          let endpoint = try? VaultMacEndpoint(host: "\(name).local", port: advertisedPort, reachability: .lanBonjour),
                          let record = try? VaultMacDiscoveryRecord(displayName: name, endpoint: endpoint, serverBinding: binding) else { continue }
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
        guard try await identityConfirmer.confirm(fingerprint: credential.fingerprint,
                                                   endpointBinding: credential.endpointBinding) else {
            throw VaultMacProtocolError.unconfirmedServerIdentity
        }
        let response = try VaultMacSessionResponse.make(challenge: challenge, credential: credential,
            clientNonce: random.bytes(count: 32), now: now())
        try await channel.send(JSONEncoder().encode(VaultMacHandshakeMessage(kind: .response, response: response)))
        let accepted = try JSONDecoder().decode(VaultMacHandshakeMessage.self, from: try await channel.receive())
        guard accepted.kind == .accepted else { throw VaultMacProtocolError.authenticationFailed }
        let keys = try VaultMacSessionKeys(challenge: challenge, response: response, credential: credential, now: now())
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

public actor VaultMacRemoteBackend: VaultBackendTransport {
    private let endpoint: VaultMacEndpoint
    private let credential: VaultMacPairingCredential
    private let connector: VaultMacFrameConnecting
    private let identityConfirmer: VaultMacServerIdentityConfirming
    private let random: VaultRandomBytesGenerating
    private var revisions: [VaultObjectID: VaultRevision] = [:]

    public init(endpoint: VaultMacEndpoint, credential: VaultMacPairingCredential,
                connector: VaultMacFrameConnecting, identityConfirmer: VaultMacServerIdentityConfirming,
                random: VaultRandomBytesGenerating = SystemVaultRandomBytes()) throws {
        guard endpoint.binding == credential.endpointBinding else { throw VaultMacProtocolError.invalidEndpoint }
        self.endpoint = endpoint; self.credential = credential; self.connector = connector
        self.identityConfirmer = identityConfirmer; self.random = random
    }

    public func putCiphertext(_ ciphertext: Data, for id: VaultObjectID) async throws {
        let plan = try VaultMacChunkPlan(byteCount: UInt64(ciphertext.count))
        let previous = try await remoteRevision(for: id)
        let revision = VaultRevision(objectID: id, logicalTime: Int64(Date().timeIntervalSince1970 * 1_000), deviceID: "iphone")
        let client = try await makeClient()
        defer { Task { await client.close() } }
        for index in 0..<plan.totalChunks {
            let range = try plan.range(for: index)
            let request = VaultMacRequest(operation: .putChunk, objectID: id, revision: revision,
                expectedRevision: previous?.revision, chunkIndex: index, totalChunks: plan.totalChunks,
                totalCiphertextBytes: UInt64(ciphertext.count),
                idempotencyKey: VaultMacRequestFactory.idempotencyKey(objectID: id, revision: revision.revision, chunkIndex: index),
                ciphertext: Data(ciphertext[range]))
            let response = try await client.request(request)
            guard response.status == .partial || response.status == .accepted else { throw VaultMacProtocolError.conflictingRevision }
        }
        revisions[id] = revision
    }

    public func ciphertext(for id: VaultObjectID) async throws -> Data? {
        let client = try await makeClient(); defer { Task { await client.close() } }
        let stat = try await client.request(VaultMacRequest(operation: .stat, objectID: id, idempotencyKey: UUID().uuidString))
        guard stat.status != .notFound else { return nil }
        guard stat.status == .accepted, let total = stat.totalCiphertextBytes,
              total <= VaultMacProtocol.maximumObjectBytes else { throw VaultMacProtocolError.invalidFrame }
        var output = Data(); if total <= UInt64(Int.max) { output.reserveCapacity(Int(total)) }
        var offset: UInt64 = 0
        while offset < total {
            let length = min(UInt64(VaultMacProtocol.maximumFrameBytes), total - offset)
            let response = try await client.request(VaultMacRequest(operation: .readRange, objectID: id,
                offset: offset, length: length, idempotencyKey: UUID().uuidString))
            guard response.status == .accepted, let bytes = response.ciphertext,
                  UInt64(bytes.count) == length else { throw VaultMacProtocolError.invalidFrame }
            output.append(bytes); offset += length
        }
        return output
    }

    public func removeCiphertext(for id: VaultObjectID) async throws {
        guard let current = try await remoteRevision(for: id) else { return }
        let tombstone = VaultRevision(objectID: id, logicalTime: max(current.logicalTime + 1,
            Int64(Date().timeIntervalSince1970 * 1_000)), deviceID: "iphone")
        let client = try await makeClient(); defer { Task { await client.close() } }
        let response = try await client.request(VaultMacRequest(operation: .delete, objectID: id,
            revision: tombstone, expectedRevision: current.revision, idempotencyKey: UUID().uuidString))
        guard response.status == .accepted || response.status == .notFound else { throw VaultMacProtocolError.conflictingRevision }
        revisions[id] = tombstone
    }

    private func remoteRevision(for id: VaultObjectID) async throws -> VaultRevision? {
        if let revision = revisions[id] { return revision }
        let client = try await makeClient(); defer { Task { await client.close() } }
        let stat = try await client.request(VaultMacRequest(operation: .stat, objectID: id, idempotencyKey: UUID().uuidString))
        guard stat.status != .notFound, let revision = stat.revision else { return nil }
        revisions[id] = revision; return revision
    }

    private func makeClient() async throws -> VaultMacSessionClient {
        let client = VaultMacSessionClient(channel: try await connector.connect(to: endpoint),
            credential: credential, identityConfirmer: identityConfirmer, random: random)
        try await client.authenticate(); return client
    }
}

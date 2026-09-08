import Foundation
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultMac
import LunaVaultModels
import XCTest

/// Pins the Mac companion server fixes from the 2026-08-31 Vault review:
/// gate failure accounting must not punish normal session teardown, the
/// gate's peer key must be host-only, and a putChunk replay must rebuild
/// `receivedChunks` from live state rather than a value frozen at write time.
final class VaultMacServerReviewFixTests: XCTestCase {
    private let objectID = VaultObjectID(rawValue: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!)

    func testCleanClientCloseDoesNotConsumeFailureBudget() async throws {
        let root = temporary("clean-close"); defer { try? FileManager.default.removeItem(at: root) }
        let credential = try makeCredential(now: Date())
        let store = try VaultMacCompanionStore(rootURL: root, credential: credential)
        let service = VaultMacCompanionService(store: store)
        let authority = VaultMacSessionAuthority(credential: credential, random: ReviewFixRandom(seed: 1))
        // A budget of one failure per minute makes any miscounted clean close
        // visible on the very next connection from the same peer.
        let limits = VaultMacListenerLimits(maximumConnections: 8, authenticationTimeout: 5,
                                            idleTimeout: 5, maximumAuthenticationFailuresPerMinute: 1)
        let gate = VaultMacConnectionGate(limits: limits)
        let server = VaultMacChannelServer(service: service, authority: authority, limits: limits, gate: gate)

        for round in 0..<3 {
            let clientToServer = ReviewFixPipe(), serverToClient = ReviewFixPipe()
            let clientChannel = ReviewFixChannel(incoming: serverToClient, outgoing: clientToServer)
            let serverChannel = ReviewFixChannel(incoming: clientToServer, outgoing: serverToClient)
            // A real client opens one session per operation and closes when done,
            // exactly the traffic pattern the pre-fix gate mistook for an attack.
            let peer = "10.0.0.5:\(50_000 + round)"
            let serverTask = Task { await server.run(serverChannel, peer: peer) }
            let client = VaultMacSessionClient(channel: clientChannel, credential: credential,
                identityConfirmer: ReviewFixAlwaysConfirm(), random: ReviewFixRandom(seed: UInt8(2 + round)))
            try await client.authenticate()
            let response = try await client.request(VaultMacRequest(operation: .stat, objectID: objectID,
                idempotencyKey: "clean-close-\(round)"))
            XCTAssertEqual(response.status, .notFound)
            await client.close()
            await serverTask.value
        }
        // Every one of the three sessions above ended in a normal close. None
        // of them may count against the (1/minute) failure budget for this host.
        XCTAssertTrue(gate.begin(peer: "10.0.0.5", now: Date()),
            "a clean client close must not be charged as an authentication failure")
        gate.end()
    }

    func testHandshakeFailureBurnsBudgetKeyedByHostNotEphemeralPort() async throws {
        let root = temporary("port-strip"); defer { try? FileManager.default.removeItem(at: root) }
        let credential = try makeCredential(now: Date())
        let store = try VaultMacCompanionStore(rootURL: root, credential: credential)
        let service = VaultMacCompanionService(store: store)
        let authority = VaultMacSessionAuthority(credential: credential, random: ReviewFixRandom(seed: 5))
        let limits = VaultMacListenerLimits(authenticationTimeout: 5, idleTimeout: 5,
                                            maximumAuthenticationFailuresPerMinute: 1)
        let gate = VaultMacConnectionGate(limits: limits)
        let server = VaultMacChannelServer(service: service, authority: authority, limits: limits, gate: gate)
        let clientToServer = ReviewFixPipe(), serverToClient = ReviewFixPipe()
        let clientChannel = ReviewFixChannel(incoming: serverToClient, outgoing: clientToServer)
        let serverChannel = ReviewFixChannel(incoming: clientToServer, outgoing: serverToClient)
        let serverTask = Task { await server.run(serverChannel, peer: "10.0.0.9:51000") }
        // A peer that answers the challenge with a proof that does not match
        // fails the handshake immediately (authenticationFailed) — a
        // pre-session failure that must count.
        let challengeMessage = try JSONDecoder().decode(VaultMacHandshakeMessage.self,
            from: try await clientChannel.receive())
        guard let challenge = challengeMessage.challenge else {
            XCTFail("server did not send a challenge"); return
        }
        let bogusResponse = try VaultMacSessionResponse(sessionID: challenge.sessionID,
            clientNonce: Data(repeating: 1, count: 32), proof: Data(repeating: 0, count: 32))
        try await clientChannel.send(JSONEncoder().encode(VaultMacHandshakeMessage(kind: .response, response: bogusResponse)))
        await serverTask.value

        // A brand-new connection from the SAME host on a DIFFERENT ephemeral
        // port must draw on the same budget, not a fresh one keyed by the
        // full "host:port" string.
        XCTAssertFalse(gate.begin(peer: "10.0.0.9", now: Date()),
            "the gate key must strip the ephemeral port so failures from one host accumulate")
    }

    func testPutChunkReplayRebuildsReceivedChunksAfterRecordShapeChange() async throws {
        let root = temporary("replay-chunks"); defer { try? FileManager.default.removeItem(at: root) }
        let credential = try makeCredential(now: Date())
        let store = try VaultMacCompanionStore(rootURL: root, credential: credential)
        let revision = VaultRevision(objectID: objectID,
            revision: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!, logicalTime: 1, deviceID: "phone")
        // A real sealed LVF envelope: the completing chunk (index 2) drives
        // the assemble-and-authenticate path, which rejects arbitrary bytes.
        let fixture = try makeFixture(root: root, plaintext: Data([1, 2, 3, 4, 5, 6, 7, 8, 9]),
                                      revision: revision.revision)
        let bytes = fixture.bytes
        let chunks = [Data(bytes[0..<3]), Data(bytes[3..<5]), Data(bytes[5..<bytes.count])]
        let totalBytes = UInt64(chunks.reduce(0) { $0 + $1.count })
        func request(_ index: Int) -> VaultMacRequest {
            VaultMacRequest(operation: .putChunk, objectID: objectID, revision: revision,
                chunkIndex: UInt32(index), totalChunks: UInt32(chunks.count),
                totalCiphertextBytes: totalBytes, idempotencyKey: "chunk-\(index)",
                ciphertext: chunks[index], objectKind: fixture.payload.identity.kind,
                payloadGeneration: fixture.payload.identity.generation)
        }

        let first = try await store.handle(request(0))
        XCTAssertEqual(first.status, .partial)
        XCTAssertEqual(first.receivedChunks, [0])

        let second = try await store.handle(request(1))
        XCTAssertEqual(second.status, .partial)
        XCTAssertEqual(second.receivedChunks, [0, 1])

        // Replaying chunk 0's ORIGINAL request must reflect the chunks
        // received so far, not the array frozen back when only chunk 0
        // existed — a stored response still carrying the pre-fix full
        // `receivedChunks` array would answer `[0]` here instead.
        let staleReplay = try await store.handle(request(0))
        XCTAssertEqual(staleReplay.receivedChunks, [0, 1],
            "replay of an earlier chunk must rebuild receivedChunks from live upload state")

        let third = try await store.handle(request(2))
        XCTAssertEqual(third.status, .accepted)
        XCTAssertEqual(third.receivedChunks, [0, 1, 2])

        // Replaying chunk 0 again after the object is fully committed still
        // reports chunk 0's own original outcome (`.partial` — chunk 0 alone
        // never completed the object; only chunk 2's request did), but must
        // rebuild `receivedChunks` from the committed object's chunk count
        // rather than a partial record that no longer exists.
        let replayAfterCommit = try await store.handle(request(0))
        XCTAssertEqual(replayAfterCommit.status, .partial)
        XCTAssertEqual(replayAfterCommit.receivedChunks, [0, 1, 2])

        // A replay of the chunk whose OWN request completed the object does
        // report `.accepted`.
        let replayFinalChunk = try await store.handle(request(2))
        XCTAssertEqual(replayFinalChunk.status, .accepted)
        XCTAssertEqual(replayFinalChunk.receivedChunks, [0, 1, 2])
    }

    func testStrictlyNewerRevisionSupersedesStalePartialInsteadOfConflictingForever() async throws {
        let root = temporary("supersede"); defer { try? FileManager.default.removeItem(at: root) }
        let credential = try makeCredential(now: Date())
        let store = try VaultMacCompanionStore(rootURL: root, credential: credential)
        let stale = VaultRevision(objectID: objectID,
            revision: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!, logicalTime: 1, deviceID: "phone")
        // The first chunk of an upload the client never resumes, e.g. it lost
        // its own pending-upload record across a restart.
        _ = try await store.handle(VaultMacRequest(operation: .putChunk, objectID: objectID, revision: stale,
            chunkIndex: 0, totalChunks: 2, totalCiphertextBytes: 4, idempotencyKey: "stale-0",
            ciphertext: Data([1, 2]), objectKind: .content, payloadGeneration: String(repeating: "a", count: 64)))

        let fresh = VaultRevision(objectID: objectID,
            revision: UUID(uuidString: "50000000-0000-0000-0000-000000000002")!, logicalTime: 2, deviceID: "phone")
        // A single-chunk upload commits immediately, which drives the same
        // assemble-and-authenticate path a real client's LVF envelope would.
        let freshFixture = try makeFixture(root: root, plaintext: Data([9, 9, 9]), revision: fresh.revision)
        let firstFreshChunk = try await store.handle(VaultMacRequest(operation: .putChunk, objectID: objectID,
            revision: fresh, chunkIndex: 0, totalChunks: 1, totalCiphertextBytes: UInt64(freshFixture.bytes.count),
            idempotencyKey: "fresh-0", ciphertext: freshFixture.bytes,
            objectKind: freshFixture.payload.identity.kind, payloadGeneration: freshFixture.payload.identity.generation))
        XCTAssertEqual(firstFreshChunk.status, .accepted,
            "a strictly newer revision must discard the stale partial and start fresh rather than conflict forever")

        let stat = try await store.handle(VaultMacRequest(operation: .stat, objectID: objectID, idempotencyKey: "stat-1"))
        XCTAssertEqual(stat.revision, fresh)
    }

    private struct ReviewFixFixture {
        let payload: VaultAuthenticatedCiphertextFile
        let bytes: Data
    }
    private func makeFixture(root: URL, plaintext: Data, revision: UUID,
                             kind: VaultRemoteObjectKind = .content, chunkSize: Int = 8) throws -> ReviewFixFixture {
        let plaintextURL = root.appendingPathComponent("fixture-\(UUID().uuidString).plain")
        let envelopeURL = root.appendingPathComponent("fixture-\(UUID().uuidString).lvf")
        let rootKey = try VaultRootKey(version: 1, key: Data(repeating: 0x42, count: 32))
        guard FileManager.default.createFile(atPath: plaintextURL.path, contents: plaintext) else {
            throw VaultMacProtocolError.unavailable
        }
        let payload = try VaultAuthenticatedCiphertextFile.seal(
            plaintextURL: plaintextURL, fileURL: envelopeURL, vaultID: "default", kind: kind,
            objectID: objectID, revision: revision, root: rootKey, chunkSize: chunkSize,
            random: ReviewFixRandom(seed: 91))
        try? FileManager.default.removeItem(at: plaintextURL)
        return ReviewFixFixture(payload: payload, bytes: try Data(contentsOf: envelopeURL))
    }

    private func makeCredential(now: Date, fill: UInt8 = 7) throws -> VaultMacPairingCredential {
        try VaultMacPairingCredential(pairingID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            secret: VaultMacPairingSecret(rawValue: Data(repeating: fill, count: 32)),
            serverBinding: Data(repeating: 8, count: 32),
            endpointBinding: "tailscale:vault.example.ts.net:49200", createdAt: now)
    }
    private func temporary(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vault-mac-review-\(name)-\(UUID().uuidString)")
    }
}

private final class ReviewFixRandom: VaultRandomBytesGenerating, @unchecked Sendable {
    private let lock = NSLock(); private var value: UInt8
    init(seed: UInt8) { value = seed }
    func bytes(count: Int) throws -> Data { lock.lock(); defer { lock.unlock() }; defer { value &+= 1 }; return Data(repeating: value, count: count) }
}

private struct ReviewFixAlwaysConfirm: VaultMacServerIdentityConfirming {
    func confirm(fingerprint: String, endpointBinding: String) async throws
        -> VaultMacServerIdentityConfirmation? {
        VaultMacServerIdentityConfirmation(fingerprint: fingerprint, endpointBinding: endpointBinding)
    }
}

private actor ReviewFixPipe {
    private var buffered: [Data] = []
    private var waiters: [CheckedContinuation<Data, Error>] = []
    private var closed = false
    func send(_ data: Data) {
        if let waiter = waiters.first { waiters.removeFirst(); waiter.resume(returning: data) }
        else { buffered.append(data) }
    }
    func receive() async throws -> Data {
        if !buffered.isEmpty { return buffered.removeFirst() }
        if closed { throw VaultMacProtocolError.unavailable }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }
    func close() {
        closed = true
        let pending = waiters; waiters.removeAll()
        pending.forEach { $0.resume(throwing: VaultMacProtocolError.unavailable) }
    }
}
private final class ReviewFixChannel: VaultMacFrameChannel, @unchecked Sendable {
    let incoming: ReviewFixPipe, outgoing: ReviewFixPipe
    init(incoming: ReviewFixPipe, outgoing: ReviewFixPipe) { self.incoming = incoming; self.outgoing = outgoing }
    func send(_ frame: Data) async throws { await outgoing.send(frame) }
    func receive() async throws -> Data { try await incoming.receive() }
    func close() { Task { await incoming.close(); await outgoing.close() } }
}

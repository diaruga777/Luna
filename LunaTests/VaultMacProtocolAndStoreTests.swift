import Foundation
import LunaVaultBackend
import LunaVaultMac
import LunaVaultModels
import XCTest

final class VaultMacProtocolAndStoreTests: XCTestCase {
    private let objectID = VaultObjectID(rawValue: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!)

    func testOneTimePairingRequiresFingerprintAndCannotBeReused() async throws {
        let coordinator = VaultMacPairingCoordinator()
        let random = DeterministicMacRandom(seed: 1)
        let now = Date(timeIntervalSince1970: 10)
        let (offer, code) = try coordinator.createOffer(endpointBinding: "tailscale:vault.example.ts.net:49200",
            serverBinding: Data(repeating: 9, count: 32), random: random, now: now)
        let capsule = VaultMacPairingCapsule(offer: offer, oneTimeCode: code)
        let client = try await VaultMacPairingClient.prepareEnrollment(capsule: capsule,
            identityConfirmer: AlwaysConfirmMacIdentity(),
            random: DeterministicMacRandom(seed: 4), now: now)
        let enrollment = client.enrollment
        XCTAssertThrowsError(try coordinator.enroll(enrollment, confirmedFingerprint: false, now: now))
        let credential = try coordinator.enroll(enrollment, confirmedFingerprint: true, now: now)
        XCTAssertEqual(credential, client.credential)
        XCTAssertEqual(credential.serverBinding, offer.serverBinding)
        XCTAssertEqual(credential.endpointBinding, offer.endpointBinding)
        XCTAssertThrowsError(try coordinator.enroll(enrollment, confirmedFingerprint: true, now: now))
    }

    func testFreshSessionDerivesDirectionalAEADAndRejectsReplayOrGaps() throws {
        let now = Date(timeIntervalSince1970: 20), credential = try makeCredential(now: now)
        let authority = VaultMacSessionAuthority(credential: credential, random: DeterministicMacRandom(seed: 2))
        let challenge = try authority.issue(now: now)
        let response = try VaultMacSessionResponse.make(challenge: challenge, credential: credential,
            clientNonce: Data(repeating: 5, count: 32), now: now)
        let (_, keys, acceptance) = try authority.accept(response, now: now)
        XCTAssertNoThrow(try acceptance.verify(challenge: challenge, response: response,
                                                credential: credential, now: now))
        XCTAssertNotEqual(keys.requestKey, keys.responseKey)
        XCTAssertThrowsError(try authority.accept(response, now: now))

        let encodedRequest = try JSONEncoder().encode(VaultMacRequest(operation: .stat,
            objectID: objectID, idempotencyKey: "secret-operation"))
        let first = try VaultMacAuthenticatedFrame.seal(plaintext: encodedRequest,
            sessionID: challenge.sessionID, direction: .request, sequence: 1, key: keys.requestKey)
        let wire = try JSONEncoder().encode(first)
        XCTAssertFalse(String(decoding: wire, as: UTF8.self).contains(objectID.rawValue.uuidString))
        XCTAssertFalse(String(decoding: wire, as: UTF8.self).contains("secret-operation"))
        let receiver = VaultMacReplayGuard(key: keys.requestKey, sessionID: challenge.sessionID, direction: .request)
        let gap = try VaultMacAuthenticatedFrame.seal(plaintext: Data([2]),
            sessionID: challenge.sessionID, direction: .request, sequence: 2, key: keys.requestKey)
        XCTAssertThrowsError(try receiver.open(gap)) { XCTAssertEqual($0 as? VaultMacProtocolError, .outOfOrderFrame) }
        XCTAssertEqual(try receiver.open(first), encodedRequest)
        XCTAssertThrowsError(try receiver.open(first)) { XCTAssertEqual($0 as? VaultMacProtocolError, .replayedFrame) }
        XCTAssertThrowsError(try first.open(key: keys.responseKey, expectedSessionID: challenge.sessionID,
                                           expectedDirection: .request))
    }

    func testInvalidSessionProofDoesNotBurnChallenge() throws {
        let now = Date(timeIntervalSince1970: 20), credential = try makeCredential(now: now)
        let authority = VaultMacSessionAuthority(credential: credential, random: DeterministicMacRandom(seed: 12))
        let challenge = try authority.issue(now: now)
        let invalid = try VaultMacSessionResponse(sessionID: challenge.sessionID,
            clientNonce: Data(repeating: 4, count: 32), proof: Data(repeating: 0, count: 32))
        XCTAssertThrowsError(try authority.accept(invalid, now: now))
        let valid = try VaultMacSessionResponse.make(challenge: challenge, credential: credential,
            clientNonce: Data(repeating: 4, count: 32), now: now)
        XCTAssertNoThrow(try authority.accept(valid, now: now))
    }

    func testServerAcceptanceProofRejectsMITMAndRotationInvalidatesOldEpoch() async throws {
        let now = Date(timeIntervalSince1970: 20), credential = try makeCredential(now: now)
        let authority = VaultMacSessionAuthority(credential: credential,
            random: DeterministicMacRandom(seed: 15))
        let connector = LoopbackMacConnector(service: nil, authority: authority,
                                             tamperAcceptance: true)
        let endpoint = try VaultMacEndpoint(binding: credential.endpointBinding)
        let channel = try await connector.connect(to: endpoint)
        let client = VaultMacSessionClient(channel: channel, credential: credential,
            identityConfirmer: AlwaysConfirmMacIdentity(), random: DeterministicMacRandom(seed: 16),
            now: { now })
        do {
            try await client.authenticate()
            XCTFail("accepted a server without the credential-bound transcript proof")
        } catch {
            XCTAssertEqual(error as? VaultMacProtocolError, .authenticationFailed)
        }

        XCTAssertThrowsError(try authority.rotate(to: credential))
        let lower = try VaultMacPairingCredential(pairingID: credential.pairingID,
            secret: credential.secret, serverBinding: credential.serverBinding,
            endpointBinding: credential.endpointBinding, epoch: 1, createdAt: now)
        XCTAssertThrowsError(try authority.rotate(to: lower))
        let replacement = try credential.rotated(secret: VaultMacPairingSecret(
            rawValue: Data(repeating: 19, count: 32)), serverBinding: Data(repeating: 20, count: 32),
            endpointBinding: credential.endpointBinding, now: now)
        try authority.rotate(to: replacement)
        XCTAssertFalse(authority.isCredentialUsable(epoch: credential.epoch))
        XCTAssertTrue(authority.isCredentialUsable(epoch: replacement.epoch))
    }

    func testEndpointValidationOnlyAcceptsTailscaleOrBonjourShapes() throws {
        XCTAssertNoThrow(try VaultMacEndpoint(host: "vault.example.ts.net", port: 49_200, reachability: .tailscale))
        XCTAssertNoThrow(try VaultMacEndpoint(host: "100.64.0.1", port: 49_200, reachability: .tailscale))
        XCTAssertNoThrow(try VaultMacEndpoint(host: "vault-mac.local", port: 49_200, reachability: .lanBonjour))
        XCTAssertThrowsError(try VaultMacEndpoint(host: "https://example.com/path", port: 49_200, reachability: .tailscale))
        XCTAssertThrowsError(try VaultMacEndpoint(host: "8.8.8.8", port: 49_200, reachability: .tailscale))
        XCTAssertThrowsError(try VaultMacEndpoint(host: "0.0.0.0", port: 49_200, reachability: .lanBonjour))
        XCTAssertThrowsError(try VaultMacEndpoint(host: "fd7a:115c:a1e0:broken", port: 49_200, reachability: .tailscale))
        XCTAssertNoThrow(try VaultMacEndpoint(binding: "tailscale:vault.example.ts.net:49200"))
        XCTAssertThrowsError(try VaultMacEndpoint(binding: "tailscale:8.8.8.8:49200"))
        let resolution = try VaultMacBonjourBrowser.Resolution(serverBinding: Data(repeating: 1, count: 32),
                                                               port: 55_555)
        XCTAssertEqual(resolution.port, 55_555, "Bonjour must use the resolved SRV port")
        #if canImport(Network)
        let root = temporary("listener-bind")
        defer { try? FileManager.default.removeItem(at: root) }
        let credential = try makeCredential(now: Date())
        let store = try VaultMacCompanionStore(rootURL: root, credential: credential)
        let service = VaultMacCompanionService(store: store)
        let authority = VaultMacSessionAuthority(credential: credential)
        for wildcard in ["0.0.0.0", "[0.0.0.0]", "::", "[::]", "[0:0:0:0:0:0:0:0]", "*"] {
            XCTAssertThrowsError(try VaultMacTCPListener(bindHost: wildcard,
                service: service, authority: authority), "wildcard bind escaped validation: \(wildcard)")
        }
        #endif
    }

    func testCredentialAndDirectoriesAreOwnerOnlyAndRevocable() throws {
        let directory = temporary("credential"), url = directory.appendingPathComponent("pairing.credential")
        defer { try? FileManager.default.removeItem(at: directory) }
        let credential = try makeCredential(now: Date())
        let credentials = VaultMacPairedCredentialStore()
        try credentials.save(credential, at: url)
        XCTAssertEqual(try credentials.load(from: url), credential)
        #if canImport(Darwin)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        #endif
        try credentials.revoke(at: url)
        XCTAssertNotNil(try credentials.load(from: url).revokedAt)
    }

    func testCompanionResumesChunksExactRangesIdempotencyAndEncryptedManifest() async throws {
        let root = temporary("store"); defer { try? FileManager.default.removeItem(at: root) }
        let credential = try makeCredential(now: Date())
        let store = try VaultMacCompanionStore(rootURL: root, credential: credential)
        let revision = VaultRevision(objectID: objectID,
            revision: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            logicalTime: 1, deviceID: "phone")
        let chunks = [Data([1, 2, 3]), Data([4, 5]), Data([6, 7, 8, 9])]
        for (index, chunk) in chunks.enumerated() {
            let request = putRequest(revision: revision, index: index, chunks: chunks, body: chunk)
            let response = try await store.handle(request)
            XCTAssertEqual(response.status, index == chunks.count - 1 ? .accepted : .partial)
            let replayedResponse = try await store.handle(request)
            XCTAssertEqual(replayedResponse, response, "exact retry returns recorded response")
            var mismatch = request
            mismatch = VaultMacRequest(operation: .putChunk, objectID: objectID, revision: revision,
                chunkIndex: UInt32(index), totalChunks: UInt32(chunks.count), totalCiphertextBytes: 9,
                idempotencyKey: request.idempotencyKey, ciphertext: Data([0]))
            do { _ = try await store.handle(mismatch); XCTFail("idempotency mismatch accepted") }
            catch { XCTAssertEqual(error as? VaultMacCompanionError, .conflict) }
        }
        let range = try await store.handle(VaultMacRequest(operation: .readRange, objectID: objectID,
            offset: 2, length: 5, idempotencyKey: "read-1"))
        XCTAssertEqual(range.ciphertext, Data([3, 4, 5, 6, 7]))
        do {
            _ = try await store.handle(VaultMacRequest(operation: .readRange, objectID: objectID,
                offset: 8, length: 2, idempotencyKey: "past-end"))
            XCTFail("out-of-bounds range accepted")
        } catch { XCTAssertEqual(error as? VaultMacCompanionError, .invalidRange) }
        let orphan = root.appendingPathComponent("objects")
            .appendingPathComponent(objectID.rawValue.uuidString)
            .appendingPathComponent("FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data([0]).write(to: orphan.appendingPathComponent(".ciphertext-staging-crash"))
        let reopened = try VaultMacCompanionStore(rootURL: root, credential: credential)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        let full = try await reopened.handle(VaultMacRequest(operation: .readRange, objectID: objectID,
            offset: 0, length: 9, idempotencyKey: "read-2"))
        XCTAssertEqual(full.ciphertext, Data([1, 2, 3, 4, 5, 6, 7, 8, 9]))
        let manifest = try Data(contentsOf: root.appendingPathComponent("manifest.v2"))
        XCTAssertFalse(String(decoding: manifest, as: UTF8.self).contains("phone"))
        XCTAssertThrowsError(try VaultMacCompanionStore(rootURL: root, credential: makeCredential(now: Date(), fill: 3)))
    }

    func testExpectedManifestSymlinkFailsRecoveryClosed() throws {
        #if canImport(Darwin)
        let root = temporary("manifest-symlink"), outside = temporary("outside-manifest")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let credential = try makeCredential(now: Date())
        _ = try VaultMacCompanionStore(rootURL: root, credential: credential)
        let manifest = root.appendingPathComponent("manifest.v2")
        try FileManager.default.removeItem(at: manifest)
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: outside)
        XCTAssertThrowsError(try VaultMacCompanionStore(rootURL: root, credential: credential))
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
        #endif
    }

    func testQuotaAndShapeValidationOccurBeforePartialWrite() async throws {
        let root = temporary("quota"); defer { try? FileManager.default.removeItem(at: root) }
        let store = try VaultMacCompanionStore(rootURL: root, credential: makeCredential(now: Date()),
            limits: VaultMacCompanionLimits(maximumStoredBytes: 4))
        let revision = VaultRevision(objectID: objectID, logicalTime: 1, deviceID: "phone")
        let request = VaultMacRequest(operation: .putChunk, objectID: objectID, revision: revision,
            chunkIndex: 0, totalChunks: 1, totalCiphertextBytes: 5,
            idempotencyKey: "quota", ciphertext: Data(repeating: 1, count: 5))
        do { _ = try await store.handle(request); XCTFail("quota exceeded") }
        catch { XCTAssertEqual(error as? VaultMacCompanionError, .quotaExceeded) }
        let objects = root.appendingPathComponent("objects").appendingPathComponent(objectID.rawValue.uuidString)
        XCTAssertFalse(FileManager.default.fileExists(atPath: objects.path))
        XCTAssertThrowsError(try VaultMacChunkPlan(byteCount: VaultMacProtocol.maximumObjectBytes + 1))
        XCTAssertEqual(try VaultMacChunkPlan(byteCount: VaultMacProtocol.maximumObjectBytes).byteCount,
                       VaultMacProtocol.maximumObjectBytes)
    }

    func testTombstoneCanBeReplacedOnlyByLegitimateNewerRevision() async throws {
        let root = temporary("tombstone"); defer { try? FileManager.default.removeItem(at: root) }
        let store = try VaultMacCompanionStore(rootURL: root, credential: makeCredential(now: Date()))
        let first = VaultRevision(objectID: objectID, logicalTime: 1, deviceID: "phone")
        _ = try await store.handle(VaultMacRequest(operation: .putChunk, objectID: objectID,
            revision: first, chunkIndex: 0, totalChunks: 1, totalCiphertextBytes: 1,
            idempotencyKey: "first", ciphertext: Data([9])))
        let tombstone = VaultRevision(objectID: objectID, logicalTime: 2, deviceID: "phone")
        let deleteResponse = try await store.handle(VaultMacRequest(operation: .delete, objectID: objectID,
            revision: tombstone, expectedRevision: first.revision, idempotencyKey: "delete"))
        XCTAssertEqual(deleteResponse.status, .accepted)
        let objectDirectory = root.appendingPathComponent("objects")
            .appendingPathComponent(objectID.rawValue.uuidString)
        XCTAssertFalse(FileManager.default.fileExists(atPath: objectDirectory.path))
        let stale = VaultRevision(objectID: objectID, logicalTime: 1, deviceID: "other")
        let staleResponse = try await store.handle(VaultMacRequest(operation: .putChunk, objectID: objectID,
            revision: stale, expectedRevision: tombstone.revision, chunkIndex: 0, totalChunks: 1,
            totalCiphertextBytes: 1, idempotencyKey: "stale", ciphertext: Data([1])))
        XCTAssertEqual(staleResponse.status, .conflict)
        let replacement = VaultRevision(objectID: objectID, logicalTime: 3, deviceID: "phone")
        let replacementResponse = try await store.handle(VaultMacRequest(operation: .putChunk, objectID: objectID,
            revision: replacement, expectedRevision: tombstone.revision, chunkIndex: 0, totalChunks: 1,
            totalCiphertextBytes: 1, idempotencyKey: "replacement", ciphertext: Data([2])))
        XCTAssertEqual(replacementResponse.status, .accepted)
    }

    func testTombstoneRevisionSurvivesRestart() async throws {
        let root = temporary("tombstone-restart"); defer { try? FileManager.default.removeItem(at: root) }
        let credential = try makeCredential(now: Date())
        let store = try VaultMacCompanionStore(rootURL: root, credential: credential)
        let live = VaultRevision(objectID: objectID, logicalTime: 10, deviceID: "phone")
        _ = try await store.handle(VaultMacRequest(operation: .putChunk, objectID: objectID,
            revision: live, chunkIndex: 0, totalChunks: 1, totalCiphertextBytes: 1,
            idempotencyKey: "restart-live", ciphertext: Data([1])))
        let tombstone = VaultRevision(objectID: objectID, logicalTime: 11, deviceID: "phone")
        _ = try await store.handle(VaultMacRequest(operation: .delete, objectID: objectID,
            revision: tombstone, expectedRevision: live.revision, idempotencyKey: "restart-delete"))
        let reopened = try VaultMacCompanionStore(rootURL: root, credential: credential)
        let stat = try await reopened.handle(VaultMacRequest(operation: .stat, objectID: objectID,
            idempotencyKey: "restart-stat"))
        XCTAssertEqual(stat.status, .notFound)
        XCTAssertEqual(stat.revision, tombstone)
    }

    func testSymlinkRootIsRejected() throws {
        #if canImport(Darwin)
        let parent = temporary("symlink"), real = parent.appendingPathComponent("real"), link = parent.appendingPathComponent("link")
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try VaultMacCompanionStore(rootURL: link, credential: makeCredential(now: Date())))
        #endif
    }

    func testRemoteBackendUsesFreshAuthenticatedSessionsEndToEnd() async throws {
        let root = temporary("remote"); defer { try? FileManager.default.removeItem(at: root) }
        let credential = try makeCredential(now: Date())
        let store = try VaultMacCompanionStore(rootURL: root, credential: credential)
        let service = VaultMacCompanionService(store: store)
        let connector = LoopbackMacConnector(service: service,
            authority: VaultMacSessionAuthority(credential: credential, random: DeterministicMacRandom(seed: 8)))
        let endpoint = try VaultMacEndpoint(host: "vault.example.ts.net", port: 49_200, reachability: .tailscale)
        let backend = try VaultMacRemoteBackend(endpoint: endpoint, credential: credential,
            connector: connector, identityConfirmer: AlwaysConfirmMacIdentity(),
            random: DeterministicMacRandom(seed: 9))
        let ciphertext = Data((0..<100).map(UInt8.init))
        try await backend.putCiphertext(ciphertext, for: objectID)
        let downloadedCiphertext = try await backend.ciphertext(for: objectID)
        XCTAssertEqual(downloadedCiphertext, ciphertext)
        try await backend.removeCiphertext(for: objectID)
        let deletedCiphertext = try await backend.ciphertext(for: objectID)
        XCTAssertNil(deletedCiphertext)
        let restartedBackend = try VaultMacRemoteBackend(endpoint: endpoint, credential: credential,
            connector: connector, identityConfirmer: AlwaysConfirmMacIdentity(),
            random: DeterministicMacRandom(seed: 10),
            uploadStateStore: VaultMacFileUploadStateStore(fileURL: root.appendingPathComponent("retry-state.json")))
        let replacement = Data([4, 3, 2, 1])
        try await restartedBackend.putCiphertext(replacement, for: objectID)
        let restartedCiphertext = try await restartedBackend.ciphertext(for: objectID)
        XCTAssertEqual(restartedCiphertext, replacement)
        let connectionCount = await connector.connectionCount
        XCTAssertGreaterThanOrEqual(connectionCount, 4)
    }

    func testLargeReadUsesMultipleSafeRangesWithoutPersistingCiphertext() async throws {
        let root = temporary("large-ranges"); defer { try? FileManager.default.removeItem(at: root) }
        let credential = try makeCredential(now: Date())
        let store = try VaultMacCompanionStore(rootURL: root, credential: credential)
        let service = VaultMacCompanionService(store: store)
        let connector = LoopbackMacConnector(service: service,
            authority: VaultMacSessionAuthority(credential: credential,
                                                random: DeterministicMacRandom(seed: 21)))
        let endpoint = try VaultMacEndpoint(binding: credential.endpointBinding)
        let state = VaultMacFileUploadStateStore(fileURL: root.appendingPathComponent("upload-state.json"))
        let backend = try VaultMacRemoteBackend(endpoint: endpoint, credential: credential,
            connector: connector, identityConfirmer: AlwaysConfirmMacIdentity(),
            random: DeterministicMacRandom(seed: 22), uploadStateStore: state)
        let size = VaultMacProtocol.maximumTransferBytes * 2 + 7
        let bytes = Data((0..<size).map { UInt8($0 % 251) })
        try await backend.putCiphertext(bytes, for: objectID)
        let downloaded = try await backend.ciphertext(for: objectID)
        XCTAssertEqual(downloaded, bytes)
        let manifestSize = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("manifest.v2").path)[.size] as? NSNumber
        XCTAssertLessThan(manifestSize?.intValue ?? .max, 256 * 1024,
                          "range ciphertext must not be retained in the idempotency manifest")
    }

    func testInterruptedUploadResumesDurableRevisionAcrossBackendRestart() async throws {
        let root = temporary("resume"); defer { try? FileManager.default.removeItem(at: root) }
        let credential = try makeCredential(now: Date())
        let store = try VaultMacCompanionStore(rootURL: root, credential: credential)
        let connector = LoopbackMacConnector(service: VaultMacCompanionService(store: store),
            authority: VaultMacSessionAuthority(credential: credential,
                                                random: DeterministicMacRandom(seed: 31)),
            failAfterFirstPutChunkOnce: true)
        let endpoint = try VaultMacEndpoint(binding: credential.endpointBinding)
        let stateURL = root.appendingPathComponent("client-state.json")
        let bytes = Data(repeating: 0x5a, count: VaultMacProtocol.maximumTransferBytes + 1)
        let first = try VaultMacRemoteBackend(endpoint: endpoint, credential: credential,
            connector: connector, identityConfirmer: AlwaysConfirmMacIdentity(),
            random: DeterministicMacRandom(seed: 32),
            uploadStateStore: VaultMacFileUploadStateStore(fileURL: stateURL))
        do { try await first.putCiphertext(bytes, for: objectID); XCTFail("upload was not interrupted") }
        catch { XCTAssertEqual(error as? VaultMacProtocolError, .unavailable) }
        let pendingBeforeRestart = try await VaultMacFileUploadStateStore(fileURL: stateURL)
            .pendingUpload(for: objectID)
        XCTAssertNotNil(pendingBeforeRestart)
        let restarted = try VaultMacRemoteBackend(endpoint: endpoint, credential: credential,
            connector: connector, identityConfirmer: AlwaysConfirmMacIdentity(),
            random: DeterministicMacRandom(seed: 33),
            uploadStateStore: VaultMacFileUploadStateStore(fileURL: stateURL))
        try await restarted.putCiphertext(bytes, for: objectID)
        let storedRevision = await store.currentRevision(for: objectID)
        XCTAssertEqual(storedRevision, pendingBeforeRestart?.revision)
        let downloaded = try await restarted.ciphertext(for: objectID)
        XCTAssertEqual(downloaded, bytes)
    }

    func testClientConnectTimeoutIsBounded() async throws {
        let credential = try makeCredential(now: Date())
        let endpoint = try VaultMacEndpoint(binding: credential.endpointBinding)
        let backend = try VaultMacRemoteBackend(endpoint: endpoint, credential: credential,
            connector: HangingMacConnector(), identityConfirmer: AlwaysConfirmMacIdentity(),
            timeouts: VaultMacClientTimeouts(connect: 1, authenticate: 1, request: 1),
            uploadStateStore: VaultMacFileUploadStateStore(fileURL: temporary("timeout-state")))
        let started = Date()
        do { _ = try await backend.ciphertext(for: objectID); XCTFail("connect did not time out") }
        catch { XCTAssertEqual(error as? VaultMacProtocolError, .expired) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
    }

    private func makeCredential(now: Date, fill: UInt8 = 7) throws -> VaultMacPairingCredential {
        try VaultMacPairingCredential(pairingID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            secret: VaultMacPairingSecret(rawValue: Data(repeating: fill, count: 32)),
            serverBinding: Data(repeating: 8, count: 32),
            endpointBinding: "tailscale:vault.example.ts.net:49200", createdAt: now)
    }
    private func temporary(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vault-mac-\(name)-\(UUID().uuidString)")
    }
    private func putRequest(revision: VaultRevision, index: Int, chunks: [Data], body: Data) -> VaultMacRequest {
        VaultMacRequest(operation: .putChunk, objectID: objectID, revision: revision,
            chunkIndex: UInt32(index), totalChunks: UInt32(chunks.count),
            totalCiphertextBytes: UInt64(chunks.reduce(0) { $0 + $1.count }),
            idempotencyKey: VaultMacRequestFactory.idempotencyKey(objectID: objectID,
                revision: revision.revision, chunkIndex: UInt32(index)), ciphertext: body)
    }
}

private final class DeterministicMacRandom: VaultRandomBytesGenerating, @unchecked Sendable {
    private let lock = NSLock(); private var value: UInt8
    init(seed: UInt8) { value = seed }
    func bytes(count: Int) throws -> Data { lock.lock(); defer { lock.unlock() }; defer { value &+= 1 }; return Data(repeating: value, count: count) }
}
private struct AlwaysConfirmMacIdentity: VaultMacServerIdentityConfirming {
    func confirm(fingerprint: String, endpointBinding: String) async throws
        -> VaultMacServerIdentityConfirmation? {
        VaultMacServerIdentityConfirmation(fingerprint: fingerprint, endpointBinding: endpointBinding)
    }
}

private actor LoopbackPipe {
    private var values: [Data] = []; private var waiters: [CheckedContinuation<Data, Error>] = []; private var closed = false
    func send(_ data: Data) { if let waiter = waiters.first { waiters.removeFirst(); waiter.resume(returning: data) } else { values.append(data) } }
    func receive() async throws -> Data {
        if !values.isEmpty { return values.removeFirst() }
        if closed { throw VaultMacProtocolError.unavailable }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }
    func close() { closed = true; let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume(throwing: VaultMacProtocolError.unavailable) } }
}
private final class LoopbackChannel: VaultMacFrameChannel, @unchecked Sendable {
    let incoming: LoopbackPipe, outgoing: LoopbackPipe
    init(incoming: LoopbackPipe, outgoing: LoopbackPipe) { self.incoming = incoming; self.outgoing = outgoing }
    func send(_ frame: Data) async throws { await outgoing.send(frame) }
    func receive() async throws -> Data { try await incoming.receive() }
    func close() { Task { await incoming.close(); await outgoing.close() } }
}
private actor LoopbackMacConnector: VaultMacFrameConnecting {
    let service: VaultMacCompanionService?, authority: VaultMacSessionAuthority
    let tamperAcceptance: Bool
    private var failAfterFirstPutChunkOnce: Bool
    private(set) var connectionCount = 0
    init(service: VaultMacCompanionService?, authority: VaultMacSessionAuthority,
         tamperAcceptance: Bool = false, failAfterFirstPutChunkOnce: Bool = false) {
        self.service = service; self.authority = authority
        self.tamperAcceptance = tamperAcceptance
        self.failAfterFirstPutChunkOnce = failAfterFirstPutChunkOnce
    }
    private func consumePutInterruption() -> Bool {
        guard failAfterFirstPutChunkOnce else { return false }
        failAfterFirstPutChunkOnce = false; return true
    }
    func connect(to endpoint: VaultMacEndpoint) async throws -> VaultMacFrameChannel {
        connectionCount += 1
        let clientInbound = LoopbackPipe(), serverInbound = LoopbackPipe()
        let client = LoopbackChannel(incoming: clientInbound, outgoing: serverInbound)
        let server = LoopbackChannel(incoming: serverInbound, outgoing: clientInbound)
        Task { [service, authority, tamperAcceptance] in
            do {
                let challenge = try authority.issue()
                try await server.send(JSONEncoder().encode(VaultMacHandshakeMessage(kind: .challenge, challenge: challenge)))
                let message = try JSONDecoder().decode(VaultMacHandshakeMessage.self, from: try await server.receive())
                guard let response = message.response else { throw VaultMacProtocolError.authenticationFailed }
                let (_, keys, validAcceptance) = try authority.accept(response)
                let acceptance = tamperAcceptance
                    ? try VaultMacSessionAcceptance(sessionID: validAcceptance.sessionID,
                        proof: Data(repeating: 0, count: 32))
                    : validAcceptance
                try await server.send(JSONEncoder().encode(VaultMacHandshakeMessage(
                    kind: .accepted, acceptance: acceptance)))
                guard let service else { server.close(); return }
                let receiver = VaultMacReplayGuard(key: keys.requestKey, sessionID: challenge.sessionID, direction: .request)
                let sender = VaultMacSendSequence(key: keys.responseKey, sessionID: challenge.sessionID, direction: .response)
                while true {
                    let frame = try JSONDecoder().decode(VaultMacAuthenticatedFrame.self, from: try await server.receive())
                    let request = try JSONDecoder().decode(VaultMacRequest.self, from: receiver.open(frame))
                    let response = await service.handle(request)
                    try await server.send(JSONEncoder().encode(try sender.seal(JSONEncoder().encode(response))))
                    if request.operation == .putChunk, await self.consumePutInterruption() {
                        server.close(); return
                    }
                }
            } catch { server.close() }
        }
        return client
    }
}

private struct HangingMacConnector: VaultMacFrameConnecting {
    func connect(to endpoint: VaultMacEndpoint) async throws -> VaultMacFrameChannel {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        throw VaultMacProtocolError.unavailable
    }
}

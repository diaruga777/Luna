import Foundation
import LunaVaultBackend
import LunaVaultMac
import LunaVaultModels
import XCTest

final class VaultMacProtocolAndStoreTests: XCTestCase {
    private let objectID = VaultObjectID(rawValue: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!)

    func testPairingBindsSessionAndRejectsWrongSecretOrTranscript() throws {
        let secret = try VaultMacPairingSecret(rawValue: Data(repeating: 7, count: 32))
        let wrong = try VaultMacPairingSecret(rawValue: Data(repeating: 8, count: 32))
        let challenge = try VaultMacPairingChallenge(sessionID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!, nonce: Data(repeating: 3, count: 32), serverBinding: Data("mac-certificate-binding".utf8))
        let response = VaultMacPairingResponse(sessionID: challenge.sessionID, proof: challenge.proof(using: secret))
        XCTAssertNoThrow(try challenge.verify(response, using: secret))
        XCTAssertThrowsError(try challenge.verify(response, using: wrong))
        XCTAssertThrowsError(try challenge.verify(VaultMacPairingResponse(sessionID: UUID(), proof: response.proof), using: secret))
    }

    func testPairedCredentialIsOwnerOnlyAndRevocable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vault-mac-credential-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("pairing.credential")
        let secret = try VaultMacPairingSecret(rawValue: Data(repeating: 2, count: 32))
        let credentials = VaultMacPairedCredentialStore()
        try credentials.save(secret, at: url)
        XCTAssertEqual(try credentials.load(from: url), secret)
        #if canImport(Darwin)
        XCTAssertEqual((FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        #endif
        try credentials.revoke(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAuthenticatedFramesAreOpaqueAndReplayProtected() throws {
        let secret = try VaultMacPairingSecret(rawValue: Data(repeating: 1, count: 32))
        let session = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let sender = VaultMacSendSequence(secret: secret, sessionID: session)
        let receiver = VaultMacReplayGuard(secret: secret, sessionID: session)
        let frame = try sender.seal(Data("ciphertext-only".utf8))
        XCTAssertEqual(try receiver.open(frame), Data("ciphertext-only".utf8))
        XCTAssertThrowsError(try receiver.open(frame)) { XCTAssertEqual($0 as? VaultMacProtocolError, .replayedFrame) }
        XCTAssertThrowsError(try sender.seal(Data(repeating: 9, count: VaultMacProtocol.maximumFrameBytes + 1)))
        var tampered = try sender.seal(Data("next".utf8))
        tampered.tag[0] ^= 1
        XCTAssertThrowsError(try receiver.open(tampered)) { XCTAssertEqual($0 as? VaultMacProtocolError, .authenticationFailed) }
    }

    func testCompanionResumesChunksReadsRangesAndPersistsEncryptedManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-mac-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = try VaultMacPairingSecret(rawValue: Data(repeating: 5, count: 32))
        let store = try VaultMacCompanionStore(rootURL: root, secret: secret)
        let revision = VaultRevision(objectID: objectID, revision: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!, logicalTime: 1, deviceID: "phone")
        let chunks = [Data([1, 2, 3]), Data([4, 5]), Data([6, 7, 8, 9])]
        for (index, chunk) in chunks.enumerated() {
            let request = VaultMacRequest(operation: .putChunk, objectID: objectID, revision: revision, chunkIndex: UInt32(index), totalChunks: UInt32(chunks.count), idempotencyKey: VaultMacRequestFactory.idempotencyKey(objectID: objectID, revision: revision.revision, chunkIndex: UInt32(index)), ciphertext: chunk)
            let response = try await store.handle(request)
            if index < chunks.count - 1 { XCTAssertEqual(response.status, .partial) }
            else { XCTAssertEqual(response.status, .accepted) }
        }
        XCTAssertEqual(await store.storedObjectCount(), 1)
        let range = try await store.handle(VaultMacRequest(operation: .readRange, objectID: objectID, offset: 2, length: 5, idempotencyKey: "read-1"))
        XCTAssertEqual(range.status, .accepted)
        XCTAssertEqual(range.ciphertext, Data([3, 4, 5, 6, 7]))
        let reopened = try VaultMacCompanionStore(rootURL: root, secret: secret)
        let full = try await reopened.handle(VaultMacRequest(operation: .readRange, objectID: objectID, offset: 0, length: 9, idempotencyKey: "read-2"))
        XCTAssertEqual(full.ciphertext, Data([1, 2, 3, 4, 5, 6, 7, 8, 9]))
        let manifest = try Data(contentsOf: root.appendingPathComponent("manifest.v1"))
        XCTAssertFalse(String(data: manifest, encoding: .utf8)?.contains("phone") == true)
        XCTAssertThrowsError(try VaultMacCompanionStore(rootURL: root, secret: try VaultMacPairingSecret(rawValue: Data(repeating: 4, count: 32))))
    }

    func testRevisionConflictRequiresExpectedRevisionAndDeleteIsTombstoned() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-mac-conflict-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = try VaultMacPairingSecret(rawValue: Data(repeating: 6, count: 32))
        let store = try VaultMacCompanionStore(rootURL: root, secret: secret)
        let first = VaultRevision(objectID: objectID, revision: UUID(), logicalTime: 1, deviceID: "phone")
        let firstRequest = VaultMacRequest(operation: .putChunk, objectID: objectID, revision: first, chunkIndex: 0, totalChunks: 1, idempotencyKey: "first", ciphertext: Data([9]))
        let firstResponse = try await store.handle(firstRequest)
        XCTAssertEqual(firstResponse.status, .accepted)
        let newer = VaultRevision(objectID: objectID, revision: UUID(), logicalTime: 2, deviceID: "phone")
        let conflict = VaultMacRequest(operation: .putChunk, objectID: objectID, revision: newer, chunkIndex: 0, totalChunks: 1, idempotencyKey: "new", ciphertext: Data([8]))
        let conflictResponse = try await store.handle(conflict)
        XCTAssertEqual(conflictResponse.status, .conflict)
        let update = VaultMacRequest(operation: .putChunk, objectID: objectID, revision: newer, expectedRevision: first.revision, chunkIndex: 0, totalChunks: 1, idempotencyKey: "new", ciphertext: Data([8]))
        let updateResponse = try await store.handle(update)
        XCTAssertEqual(updateResponse.status, .accepted)
        let deletion = VaultMacRequest(operation: .delete, objectID: objectID, expectedRevision: newer.revision, idempotencyKey: "delete")
        let deletionResponse = try await store.handle(deletion)
        XCTAssertEqual(deletionResponse.status, .accepted)
        let readResponse = try await store.handle(VaultMacRequest(operation: .readRange, objectID: objectID, offset: 0, length: 1, idempotencyKey: "read"))
        XCTAssertEqual(readResponse.status, .notFound)
    }
}

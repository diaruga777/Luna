import CryptoKit
import Foundation
import XCTest
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultModels
import LunaVaultSetup
import LunaVaultStorage
import LunaVaultSync
import VaultTestKit

/// Pins the `VaultImportCoordinator.repairInterruptedImports` recovery
/// windows and the `LunaVaultSync` upload-payload leak fixed in the 2026-08-31
/// Vault review. Before this pass `repairInterruptedImports` had no test
/// coverage at all.
final class VaultImportRepairReviewFixTests: XCTestCase {
    private struct TestProtection: VaultFileProtectionApplying {
        func apply(to url: URL) throws {}
        func hasRequiredProtection(at url: URL) throws -> Bool { true }
    }

    /// Mirrors the private `VaultImportJournal` field-for-field. JSON keyed
    /// decoding matches by name, not by declaring type, so a journal written
    /// by this type is byte-for-byte what the coordinator itself would have
    /// written and decodes into the real (inaccessible) type during repair.
    private struct MirrorJournal: Codable {
        let objectID: VaultObjectID
        let revision: UUID
        let logicalTime: Int64
        let deviceID: String
        let fileName: String
        let contentType: String?
        let byteCount: Int64
        let createdAt: Date
        let updatedAt: Date
        let sourceName: String
        let contentDigest: String
        let remoteGeneration: String?
    }

    private func writeJournalFile(_ journal: MirrorJournal, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(journal).write(to: url)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeRemote(vaultID: String, backendKey: String, root: VaultRootKey,
                            payloadDirectory: URL) -> VaultImportRemoteConfiguration {
        VaultImportRemoteConfiguration(
            backendKey: backendKey, vaultID: vaultID, root: root,
            rootKey: { version in
                guard version == root.version else { throw VaultCryptoError.missingRootKey }
                return root
            }, payloadDirectory: payloadDirectory)
    }

    // MARK: - Finding: reseal from the retained payload when ciphertext is missing

    func testRepairReSealsFromRetainedPayloadWhenCiphertextMissing() throws {
        let directory = try VaultTemporaryDirectory(name: "repair-reseal-missing-ciphertext")
        defer { try? directory.cleanUp() }
        let protection = TestProtection()
        let repository = try VaultRepository(testContainerURL: directory.url, protectionApplier: protection)
        let root = try VaultRootKey(version: 1, key: Data(repeating: 3, count: 32))
        let uploadDirectory = directory.url.appendingPathComponent("uploads", isDirectory: true)
        let remote = makeRemote(vaultID: "repair-test", backendKey: "icloud:default",
                                root: root, payloadDirectory: uploadDirectory)
        let coordinator = try VaultImportCoordinator(
            repository: repository,
            configuration: VaultImportConfiguration(deviceID: "test", modelVersion: "fixture",
                                                     uploadBackendKey: "icloud:default", remote: remote),
            protectionApplier: protection)

        let objectID = VaultObjectID(rawValue: UUID())
        let revision = UUID()
        let bytes = Data("mid-seal crash payload survives repair".utf8)
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        let token = UUID().uuidString
        let payloadURL = coordinator.stagingDirectory.appendingPathComponent("payload-\(token)")
        try bytes.write(to: payloadURL)
        let journalURL = coordinator.stagingDirectory.appendingPathComponent("journal-\(token).json")
        try writeJournalFile(MirrorJournal(
            objectID: objectID, revision: revision, logicalTime: 1, deviceID: "test",
            fileName: "note.txt", contentType: "text/plain", byteCount: Int64(bytes.count),
            createdAt: now, updatedAt: now, sourceName: "note.txt",
            contentDigest: digest(bytes), remoteGeneration: nil), to: journalURL)
        // No ciphertext-<token>.lvf on disk: the process died before sealing
        // ever produced one.

        let results = try coordinator.repairInterruptedImports()

        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(result.objectID, objectID)
        XCTAssertEqual(result.revision, revision)
        XCTAssertEqual(try repository.readContent(for: objectID), bytes)

        let uploadJobID = try XCTUnwrap(result.uploadJobID)
        let uploadJob = try XCTUnwrap(repository.job(uploadJobID))
        XCTAssertEqual(uploadJob.kind, .upload)
        let generation = try XCTUnwrap(uploadJob.payloadGeneration)
        let stagedUpload = uploadDirectory.appendingPathComponent(
            ["content", objectID.rawValue.uuidString, revision.uuidString, generation]
                .joined(separator: "-") + ".vault")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedUpload.path),
                      "repair must reseal and stage ciphertext for the sync worker")

        let remainingStaging = try FileManager.default.contentsOfDirectory(
            at: coordinator.stagingDirectory, includingPropertiesForKeys: nil)
        XCTAssertTrue(remainingStaging.allSatisfy { $0.lastPathComponent == "Metadata" },
                      "repair must not leave the resealed journal/payload/ciphertext behind")
    }

    // MARK: - Finding: a corrupt staged payload is dropped, not retried forever

    func testRepairDropsUnrecoverablePairWhenStagedPlaintextIsCorrupt() throws {
        let directory = try VaultTemporaryDirectory(name: "repair-corrupt-payload")
        defer { try? directory.cleanUp() }
        let protection = TestProtection()
        let repository = try VaultRepository(testContainerURL: directory.url, protectionApplier: protection)
        let coordinator = try VaultImportCoordinator(repository: repository, protectionApplier: protection)

        let objectID = VaultObjectID(rawValue: UUID())
        let revision = UUID()
        let expectedBytes = Data("the complete original bytes before the crash".utf8)
        let now = Date(timeIntervalSinceReferenceDate: 2_000)

        let token = UUID().uuidString
        let payloadURL = coordinator.stagingDirectory.appendingPathComponent("payload-\(token)")
        // A crash mid-copy left only a truncated prefix on disk; the journal
        // still records the ORIGINAL byte count and digest.
        try Data("the complete origi".utf8).write(to: payloadURL)
        let journalURL = coordinator.stagingDirectory.appendingPathComponent("journal-\(token).json")
        try writeJournalFile(MirrorJournal(
            objectID: objectID, revision: revision, logicalTime: 1, deviceID: "test",
            fileName: "note.txt", contentType: "text/plain", byteCount: Int64(expectedBytes.count),
            createdAt: now, updatedAt: now, sourceName: "note.txt",
            contentDigest: digest(expectedBytes), remoteGeneration: nil), to: journalURL)

        let firstPass = try coordinator.repairInterruptedImports()
        XCTAssertTrue(firstPass.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: payloadURL.path),
                       "an unrecoverable payload must be dropped, not retained")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path),
                       "its journal must be dropped with it")
        XCTAssertNil(try repository.object(objectID))

        // A later pass finds nothing left to retry: the pair was dropped
        // once, not stranded for every future launch.
        let secondPass = try coordinator.repairInterruptedImports()
        XCTAssertTrue(secondPass.isEmpty)
    }

    // MARK: - Finding: the seal-to-stage crash window

    func testRepairStagesSealedCiphertextNeverCopiedToUploadsDirectory() throws {
        let directory = try VaultTemporaryDirectory(name: "repair-stage-upload")
        defer { try? directory.cleanUp() }
        let protection = TestProtection()
        let repository = try VaultRepository(testContainerURL: directory.url, protectionApplier: protection)
        let root = try VaultRootKey(version: 1, key: Data(repeating: 5, count: 32))
        let uploadDirectory = directory.url.appendingPathComponent("uploads", isDirectory: true)
        let remote = makeRemote(vaultID: "repair-test", backendKey: "mac:paired",
                                root: root, payloadDirectory: uploadDirectory)
        let coordinator = try VaultImportCoordinator(
            repository: repository,
            configuration: VaultImportConfiguration(deviceID: "test", modelVersion: "fixture",
                                                     uploadBackendKey: "mac:paired", remote: remote),
            protectionApplier: protection)

        let objectID = VaultObjectID(rawValue: UUID())
        let revision = UUID()
        let bytes = Data("sealed but never staged for the sync worker".utf8)
        let now = Date(timeIntervalSinceReferenceDate: 3_000)

        let token = UUID().uuidString
        let payloadURL = coordinator.stagingDirectory.appendingPathComponent("payload-\(token)")
        try bytes.write(to: payloadURL)

        // Seal the ciphertext directly with the public crypto API, exactly as
        // the coordinator's own (private) sealing step would -- but never
        // copy it into `uploadDirectory`, simulating a crash between the two.
        let ciphertextURL = coordinator.stagingDirectory.appendingPathComponent("ciphertext-\(token).lvf")
        let sealed = try VaultAuthenticatedCiphertextFile.seal(
            plaintextURL: payloadURL, fileURL: ciphertextURL, vaultID: "repair-test",
            kind: .content, objectID: objectID, revision: revision, root: root)

        let journalURL = coordinator.stagingDirectory.appendingPathComponent("journal-\(token).json")
        try writeJournalFile(MirrorJournal(
            objectID: objectID, revision: revision, logicalTime: 1, deviceID: "test",
            fileName: "note.txt", contentType: "text/plain", byteCount: Int64(bytes.count),
            createdAt: now, updatedAt: now, sourceName: "note.txt",
            contentDigest: digest(bytes), remoteGeneration: sealed.identity.generation), to: journalURL)

        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(
            at: uploadDirectory, includingPropertiesForKeys: nil))?.isEmpty ?? true,
            "precondition: nothing staged for the sync worker yet")

        let results = try coordinator.repairInterruptedImports()

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(try repository.readContent(for: objectID), bytes)
        let stagedUpload = uploadDirectory.appendingPathComponent(
            ["content", objectID.rawValue.uuidString, revision.uuidString, sealed.identity.generation]
                .joined(separator: "-") + ".vault")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedUpload.path),
                      "repair must stage the already-sealed ciphertext before finalizing")
    }

    // MARK: - Finding: re-importing after content eviction reinstalls the existing revision

    func testReimportAfterContentEvictionReinstallsExistingRevision() throws {
        let directory = try VaultTemporaryDirectory(name: "repair-evicted-duplicate")
        defer { try? directory.cleanUp() }
        let protection = TestProtection()
        let repository = try VaultRepository(testContainerURL: directory.url, protectionApplier: protection)
        let source = directory.url.appendingPathComponent("fixture.txt")
        let bytes = Data("evictable content bytes".utf8)
        try bytes.write(to: source)
        let coordinator = try VaultImportCoordinator(repository: repository, protectionApplier: protection)

        let first = try coordinator.importFile(VaultImportSource(fileURL: source, fileName: "first.txt"))
        XCTAssertEqual(try repository.readContent(for: first.objectID), bytes)
        XCTAssertNotNil(try repository.localContentCapability(for: first.objectID))

        // Simulate eviction directly on disk: the object row and metadata
        // sidecar remain, only the physical content is gone -- eviction is a
        // designed state (`VaultCacheCoordinator.evict`).
        let objectDirectory = repository.contentDirectory
            .appendingPathComponent(first.objectID.rawValue.uuidString)
        try FileManager.default.removeItem(at: objectDirectory.appendingPathComponent("content"))
        try FileManager.default.removeItem(at: objectDirectory.appendingPathComponent(".content-generation"))
        XCTAssertNil(try repository.localContentCapability(for: first.objectID))

        let second = try coordinator.importFile(VaultImportSource(fileURL: source, fileName: "second.txt"))

        XCTAssertEqual(second.objectID, first.objectID)
        XCTAssertEqual(second.revision, first.revision,
                       "an evicted-but-still-current object must resolve to its EXISTING revision")
        XCTAssertEqual(try repository.readContent(for: first.objectID), bytes)
        XCTAssertNotNil(try repository.localContentCapability(for: first.objectID))
        XCTAssertEqual(try repository.objects().count, 1)
    }

    // MARK: - Finding: the Data-path upload leaks a staged payload

    func testDataPathUploadRemovesStagedPayloadWhenBackendAlreadyCurrent() async throws {
        let directory = try VaultTemporaryDirectory(name: "upload-already-current")
        defer { try? directory.cleanUp() }
        let repository = try VaultRepository(testContainerURL: directory.url)
        let objectID = VaultObjectID(rawValue: UUID())
        let revision = UUID()
        let root = try VaultRootKey(version: 1, key: Data(repeating: 7, count: 32))
        let frames = try VaultChunkedCryptor(chunkSize: 16, vaultID: "default",
                                             random: VaultTestRandomBytes(seed: 9))
            .seal(Data("already current bytes".utf8), objectID: objectID, revision: revision, root: root)
        let payload = try VaultAuthenticatedCiphertext(vaultID: "default", kind: .content,
                                                        encryptedFrames: frames)
        // Seed the backend so the very first `state(for:)` check already
        // reports `.current` -- the short-circuit branch under test.
        let backend = InMemoryVaultBackend(values: [payload.identity: payload],
                                           states: [payload.identity: .current])
        let store = InMemoryVaultSyncPayloadStore()
        let sync = VaultSyncCoordinator(repository: repository, backend: backend,
                                        payloadSource: store, owner: "already-current")

        let result = try await sync.upload(payload)

        XCTAssertEqual(result.state, .succeeded)
        let staged = await store.stagedPayload(for: payload.identity)
        XCTAssertNil(staged, "a payload staged for an already-current backend must not be left behind")
    }
}

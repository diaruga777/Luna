import Foundation
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultModels
import LunaVaultStorage
import LunaVaultSync
import VaultTestKit
import XCTest

final class VaultBackendTests: XCTestCase {
    private let objectID = VaultObjectID(rawValue: UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!)

    func testDeviceBackendUsesProtectedLocalStoreAndSupportsRanges() async throws {
        let directory = try VaultTemporaryDirectory(name: "device-backend")
        let repository = try VaultRepository(testContainerURL: directory.url)
        let now = Date(timeIntervalSinceReferenceDate: 10)
        let record = VaultObjectRecord(id: objectID, revision: UUID(), logicalTime: 1,
                                       size: 11, contentType: "text/plain", createdAt: now,
                                       updatedAt: now, accessedAt: now)
        XCTAssertTrue(try repository.upsert(record))
        let backend = VaultDeviceBackend(store: repository)
        try await backend.putContent(Data("hello device".utf8), for: objectID)
        let range = try await backend.content(for: objectID, range: 0..<5)
        XCTAssertEqual(range, Data("hello".utf8))
        XCTAssertEqual(try repository.readContent(for: objectID), Data("hello device".utf8))
        XCTAssertFalse(backend.capabilities.requiresClientSideEncryption)
    }

    func testTypedCiphertextRejectsTamperBeforeRemoteInstall() throws {
        let payload = try makePayload("secret", revision: UUID(), seed: 1)
        var encoded = try payload.encoded(); encoded[encoded.count - 1] ^= 1
        XCTAssertThrowsError(try VaultAuthenticatedCiphertext.decodeAndValidate(
            encoded, expected: payload.identity, vaultID: "default"))
        XCTAssertThrowsError(try VaultAuthenticatedCiphertext(
            vaultID: "default", kind: .metadata,
            encryptedFrames: payload.encryptedFrames))
    }

    func testDownloadedCiphertextMustAuthenticateBeforeDurableInstall() async throws {
        let directory = try VaultTemporaryDirectory(name: "authenticated-download")
        let repository = try VaultRepository(testContainerURL: directory.url)
        let root = try VaultRootKey(version: 1, key: Data(repeating: 7, count: 32))
        let valid = try makePayload("authenticated", revision: UUID(), seed: 11)
        var frames = valid.encryptedFrames
        frames[frames.count - 1][frames.last!.count - 1] ^= 1
        let tampered = try VaultAuthenticatedCiphertext(
            vaultID: "default", kind: .content, encryptedFrames: frames)
        let backend = InMemoryVaultBackend()
        _ = try await backend.put(tampered, expectedRevision: tampered.identity.revision)
        let payloadStore = try VaultFileSyncPayloadStore(
            rootURL: directory.url.appendingPathComponent("sync"), vaultID: "default",
            rootKey: { version in
                guard version == root.version else { throw VaultCryptoError.missingRootKey }
                return root
            })
        let sync = VaultSyncCoordinator(repository: repository, backend: backend,
                                        payloadSource: payloadStore, owner: "download")
        do {
            _ = try await sync.download(tampered.identity)
            XCTFail("tampered ciphertext was installed")
        } catch let error as VaultSyncError {
            XCTAssertEqual(error, .backend(.corruptPayload))
        }
        let job = try XCTUnwrap(repository.jobs().first)
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.lastError, "backend_corrupt_payload")
    }

    func testICloudUploadRemainsDurablyPendingUntilProviderConfirmsCurrent() async throws {
        let directory = try VaultTemporaryDirectory(name: "icloud-pending")
        let repository = try VaultRepository(testContainerURL: directory.url)
        let ubiquity = InMemoryVaultUbiquitousCoordinator(); ubiquity.uploadRemainsPending = true
        let backend = makeICloud(coordinator: ubiquity)
        let store = InMemoryVaultSyncPayloadStore()
        let sync = VaultSyncCoordinator(repository: repository, backend: backend,
                                        payloadSource: store, owner: "phone",
                                        configuration: VaultSyncConfiguration(
                                            location: .iCloud, initialBackoff: 30))
        let payload = try makePayload("pending", revision: UUID(), seed: 2)
        let first = try await sync.upload(payload, now: Date(timeIntervalSinceReferenceDate: 100))
        XCTAssertEqual(first.state, .retrying)
        let pendingJob = try XCTUnwrap(repository.jobs().first)
        XCTAssertEqual(pendingJob.state, .retrying)
        XCTAssertEqual(pendingJob.lastError, VaultSyncFailureCode.uploadPending.rawValue)

        ubiquity.uploadRemainsPending = false
        let resumed = try await sync.upload(payload, wakeReason: .providerStateChanged,
                                            now: Date(timeIntervalSinceReferenceDate: 101))
        XCTAssertEqual(resumed.state, .succeeded)
        XCTAssertEqual(try XCTUnwrap(repository.jobs().first).state, .succeeded)
    }

    func testICloudRequiresCurrentDownloadAndRejectsUnresolvedConflict() async throws {
        let ubiquity = InMemoryVaultUbiquitousCoordinator()
        let backend = makeICloud(coordinator: ubiquity)
        let payload = try makePayload("current", revision: UUID(), seed: 3)
        let writeOutcome = try await backend.put(
            payload, expectedRevision: payload.identity.revision)
        XCTAssertEqual(writeOutcome, .current)
        ubiquity.downloadedIsCurrent = false
        do { _ = try await backend.payload(for: payload.identity); XCTFail("stale bytes installed") }
        catch let error as VaultBackendError { XCTAssertEqual(error, .unavailable) }
        let downloadedPayload = try await backend.payload(for: payload.identity)
        XCTAssertEqual(downloadedPayload, payload)
        ubiquity.hasUnresolvedConflicts = true
        let conflictedState = try await backend.state(for: payload.identity)
        XCTAssertEqual(conflictedState, .conflicted)
        do { _ = try await backend.payload(for: payload.identity); XCTFail("conflicted bytes installed") }
        catch let error as VaultBackendError { XCTAssertEqual(error, .conflict) }
    }

    func testICloudCASUploadFailureAndEvictionAreExplicit() async throws {
        let ubiquity = InMemoryVaultUbiquitousCoordinator()
        let backend = makeICloud(coordinator: ubiquity, keepLocal: true)
        let payload = try makePayload("cas", revision: UUID(), seed: 4)
        do { _ = try await backend.put(payload, expectedRevision: UUID()); XCTFail("stale CAS accepted") }
        catch let error as VaultBackendError { XCTAssertEqual(error, .staleVersion) }
        ubiquity.uploadFails = true
        do { _ = try await backend.put(payload, expectedRevision: payload.identity.revision); XCTFail("upload failure hidden") }
        catch let error as VaultBackendError { XCTAssertEqual(error, .uploadFailed) }
        ubiquity.uploadFails = false
        let writeOutcome = try await backend.put(
            payload, expectedRevision: payload.identity.revision)
        XCTAssertEqual(writeOutcome, .current)
        ubiquity.evictionRemainsPending = true
        let pendingEviction = try await backend.evictionOutcome(for: payload.identity)
        XCTAssertEqual(pendingEviction, .pending)
        ubiquity.evictionRemainsPending = false
        let completedEviction = try await backend.evictionOutcome(for: payload.identity)
        XCTAssertEqual(completedEviction, .evicted)
    }

    func testIdempotencySeparatesRevisionGenerationAndBackendIdentity() async throws {
        let directory = try VaultTemporaryDirectory(name: "identity-jobs")
        let repository = try VaultRepository(testContainerURL: directory.url)
        let store = InMemoryVaultSyncPayloadStore()
        let revision = UUID()
        let first = try makePayload("one", revision: revision, seed: 5)
        let generation = try makePayload("two", revision: revision, seed: 6)
        let revisionTwo = try makePayload("three", revision: UUID(), seed: 7)
        let backendA = InMemoryVaultBackend(identity: VaultBackendIdentity(
            location: .iCloud, containerIdentifier: "container-a", vaultID: "default"))
        let backendB = InMemoryVaultBackend(identity: VaultBackendIdentity(
            location: .mac, containerIdentifier: "mac-a", vaultID: "default"))
        let syncA = VaultSyncCoordinator(repository: repository, backend: backendA,
                                         payloadSource: store, owner: "a")
        let syncB = VaultSyncCoordinator(repository: repository, backend: backendB,
                                         payloadSource: store, owner: "b")
        _ = try await syncA.upload(first); _ = try await syncA.upload(generation)
        _ = try await syncA.upload(revisionTwo); _ = try await syncB.upload(first)
        let jobs = try repository.jobs()
        XCTAssertEqual(jobs.count, 4)
        XCTAssertEqual(Set(jobs.map(\.idempotencyKey)).count, 4)
        XCTAssertEqual(Set(jobs.compactMap(\.payloadGeneration)).count, 3)
        XCTAssertEqual(Set(jobs.compactMap(\.backendKey)).count, 2)
    }

    func testArtifactUploadAndRemoteDeleteAreDurable() async throws {
        let directory = try VaultTemporaryDirectory(name: "artifact-delete")
        let repository = try VaultRepository(testContainerURL: directory.url)
        let backend = InMemoryVaultBackend()
        let store = InMemoryVaultSyncPayloadStore()
        let sync = VaultSyncCoordinator(repository: repository, backend: backend,
                                        payloadSource: store, owner: "artifact")
        let payload = try makePayload("index", revision: UUID(), kind: .index, seed: 8)
        let artifact = try VaultEncryptedArtifact(
            kind: .index, vaultID: "default", revision: payload.identity.revision,
            rootVersion: payload.rootVersion, encryptedFrames: payload.encryptedFrames)
        let upload = try await sync.uploadArtifact(artifact)
        XCTAssertEqual(upload.state, .succeeded)
        let remove = try await sync.delete(payload.identity)
        XCTAssertEqual(remove.state, .succeeded)
        let state = try await backend.state(for: payload.identity)
        XCTAssertEqual(state, .missing)
        XCTAssertEqual(try repository.jobs().map(\.kind), [.upload, .delete])
    }

    func testRetriesAreBoundedAndPersistOnlyFixedRedactedCodes() async throws {
        let directory = try VaultTemporaryDirectory(name: "redacted-errors")
        let repository = try VaultRepository(testContainerURL: directory.url)
        let backend = InMemoryVaultBackend(failures: [.io])
        let sync = VaultSyncCoordinator(
            repository: repository, backend: backend,
            payloadSource: InMemoryVaultSyncPayloadStore(), owner: "retry",
            configuration: VaultSyncConfiguration(location: .mac, maximumAttempts: 1))
        let payload = try makePayload("credential=do-not-persist", revision: UUID(), seed: 9)
        do { _ = try await sync.upload(payload); XCTFail("injected failure succeeded") }
        catch let error as VaultSyncError { XCTAssertEqual(error, .backend(.io)) }
        let job = try XCTUnwrap(repository.jobs().first)
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.lastError, "backend_io")
        XCTAssertFalse(try XCTUnwrap(job.lastError).contains("credential"))
    }

    func testPendingUploadExhaustsAtConfiguredAttemptLimit() async throws {
        let directory = try VaultTemporaryDirectory(name: "pending-exhaustion")
        let repository = try VaultRepository(testContainerURL: directory.url)
        let ubiquity = InMemoryVaultUbiquitousCoordinator()
        ubiquity.uploadRemainsPending = true
        let sync = VaultSyncCoordinator(
            repository: repository, backend: makeICloud(coordinator: ubiquity),
            payloadSource: InMemoryVaultSyncPayloadStore(), owner: "bounded",
            configuration: VaultSyncConfiguration(
                location: .iCloud, maximumAttempts: 1, initialBackoff: 30))
        let result = try await sync.upload(
            makePayload("pending", revision: UUID(), seed: 10))
        XCTAssertEqual(result.state, .failed)
        let job = try XCTUnwrap(repository.jobs().first)
        XCTAssertEqual(job.attempts, 1)
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.lastError, VaultSyncFailureCode.retryExhausted.rawValue)
        XCTAssertNil(job.nextAttemptAt)
    }

    func testVaultEntitlementsAndOfflineDependencyBoundary() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let host = try String(contentsOf: root.appendingPathComponent("LunaVault/LunaVault.entitlements"), encoding: .utf8)
        let info = try String(contentsOf: root.appendingPathComponent("LunaVault/Info.plist"), encoding: .utf8)
        let share = try String(contentsOf: root.appendingPathComponent("LunaVaultShare/LunaVaultShare.entitlements"), encoding: .utf8)
        XCTAssertTrue(host.contains("com.apple.developer.ubiquity-container-identifiers"))
        XCTAssertTrue(host.contains("CloudDocuments")); XCTAssertTrue(info.contains("$(ICLOUD_CONTAINER_ID)"))
        XCTAssertFalse(share.contains("ubiquity")); XCTAssertFalse(share.contains("keychain-access-groups"))
        let package = try String(contentsOf: root.appendingPathComponent("LunaLibraries/Package.swift"), encoding: .utf8)
        let config = try String(contentsOf: root.appendingPathComponent("Config/Luna.xcconfig"), encoding: .utf8)
        XCTAssertTrue(config.contains("ICLOUD_CONTAINER_ID = iCloud.$(PRODUCT_BUNDLE_PREFIX)"))
        let extraction = try XCTUnwrap(package.range(of: ".target(name: \"LunaVaultIndexExtraction\""))
        let following = package[extraction.lowerBound...].prefix(300)
        XCTAssertFalse(following.contains("LunaVaultBackend"))
    }

    private func makeICloud(coordinator: InMemoryVaultUbiquitousCoordinator,
                            keepLocal: Bool = true) -> VaultICloudBackend {
        VaultICloudBackend(configuration: VaultICloudBackendConfiguration(
            containerIdentifier: "iCloud.example", keepLocalCopy: keepLocal,
            retryPolicy: VaultBackendRetryPolicy(maximumAttempts: 1)),
                           coordinator: coordinator)
    }

    private func makePayload(_ text: String, revision: UUID,
                             kind: VaultRemoteObjectKind = .content,
                             seed: UInt64) throws -> VaultAuthenticatedCiphertext {
        let root = try VaultRootKey(version: 1, key: Data(repeating: 7, count: 32))
        let frames = try VaultChunkedCryptor(chunkSize: 16, vaultID: "default",
                                             random: VaultTestRandomBytes(seed: seed))
            .seal(Data(text.utf8), objectID: objectID, revision: revision,
                  root: root, role: kind.envelopeRole)
        return try VaultAuthenticatedCiphertext(vaultID: "default", kind: kind,
                                                encryptedFrames: frames)
    }
}

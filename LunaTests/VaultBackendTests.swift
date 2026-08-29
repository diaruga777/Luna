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
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try payload.encoded()) as? [String: Any])
        object["vaultID"] = "other-vault"
        let wrongVault = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try VaultAuthenticatedCiphertext.decodeAndValidate(
            wrongVault, expected: payload.identity, vaultID: "default"))
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
        let backend = InMemoryVaultBackend(values: [tampered.identity: tampered])
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
            try verified(payload), expectedRevision: nil)
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
        do { _ = try await backend.put(try verified(payload), expectedRevision: UUID()); XCTFail("stale CAS accepted") }
        catch let error as VaultBackendError { XCTAssertEqual(error, .staleVersion) }
        ubiquity.uploadFails = true
        do { _ = try await backend.put(try verified(payload), expectedRevision: nil); XCTFail("upload failure hidden") }
        catch let error as VaultBackendError { XCTAssertEqual(error, .uploadFailed) }
        ubiquity.uploadFails = false
        let writeOutcome = try await backend.put(
            try verified(payload), expectedRevision: nil)
        XCTAssertEqual(writeOutcome, .current)
        ubiquity.evictionRemainsPending = true
        let pendingEviction = try await backend.evictionOutcome(for: payload.identity)
        XCTAssertEqual(pendingEviction, .pending)
        ubiquity.evictionRemainsPending = false
        let completedEviction = try await backend.evictionOutcome(for: payload.identity)
        XCTAssertEqual(completedEviction, .evicted)
    }

    func testICloudCASRejectsDeterministicStaleWriterAgainstRemoteHead() async throws {
        let ubiquity = InMemoryVaultUbiquitousCoordinator()
        let backend = makeICloud(coordinator: ubiquity)
        let first = try makePayload("first", revision: UUID(), seed: 41)
        let second = try makePayload("second", revision: UUID(), seed: 42)
        let stale = try makePayload("stale", revision: UUID(), seed: 43)

        let firstOutcome = try await backend.put(try verified(first), expectedRevision: nil)
        XCTAssertEqual(firstOutcome, .current)
        let secondOutcome = try await backend.put(
            try verified(second), expectedRevision: first.identity.revision)
        XCTAssertEqual(secondOutcome, .current)
        do {
            _ = try await backend.put(
                try verified(stale), expectedRevision: first.identity.revision)
            XCTFail("stale writer replaced the provider head")
        } catch let error as VaultBackendError {
            XCTAssertEqual(error, .staleVersion)
        }
        do {
            try await backend.remove(first.identity, expectedRevision: first.identity.revision)
            XCTFail("stale delete removed a newer provider head")
        } catch let error as VaultBackendError {
            XCTAssertEqual(error, .staleVersion)
        }
        let current = try await backend.payload(for: second.identity)
        XCTAssertEqual(current, second)
    }

    func testUnknownProviderDownloadStatusNeverConfirmsEviction() async throws {
        let ubiquity = InMemoryVaultUbiquitousCoordinator()
        let backend = makeICloud(coordinator: ubiquity)
        let payload = try makePayload("unknown", revision: UUID(), seed: 44)
        _ = try await backend.put(try verified(payload), expectedRevision: nil)
        ubiquity.downloadStatusIsKnown = false
        ubiquity.evictionRemainsPending = true
        let outcome = try await backend.evictionOutcome(for: payload.identity)
        XCTAssertEqual(outcome, .pending)
        do {
            _ = try await backend.payload(for: payload.identity)
            XCTFail("unknown provider status was treated as a current download")
        } catch let error as VaultBackendError {
            XCTAssertEqual(error, .unavailable)
        }
    }

    func testOutboundStagingRejectsTamperBeforeBackendCapability() async throws {
        let directory = try VaultTemporaryDirectory(name: "outbound-auth")
        let valid = try makePayload("outbound", revision: UUID(), seed: 45)
        var frames = valid.encryptedFrames
        frames[frames.count - 1][frames.last!.count - 1] ^= 1
        let tampered = try VaultAuthenticatedCiphertext(
            vaultID: "default", kind: .content, encryptedFrames: frames)
        let store = try VaultFileSyncPayloadStore(
            rootURL: directory.url, vaultID: "default",
            rootKey: { _ in try VaultRootKey(version: 1, key: Data(repeating: 7, count: 32)) })
        do {
            try await store.stageUpload(tampered)
            XCTFail("tampered outbound ciphertext was staged")
        } catch let error as VaultSyncError {
            XCTAssertEqual(error, .backend(.corruptPayload))
        }
        let staged = try await store.uploadPayload(for: tampered.identity)
        XCTAssertNil(staged)
    }

    func testDownloadedContentLinksRepositoryAndDeleteCleansBothStagingAreas() async throws {
        let directory = try VaultTemporaryDirectory(name: "download-linkage")
        let repository = try VaultRepository(testContainerURL: directory.url)
        let payload = try makePayload("linked-content", revision: UUID(), seed: 46)
        let now = Date(timeIntervalSinceReferenceDate: 400)
        XCTAssertTrue(try repository.upsert(VaultObjectRecord(
            id: objectID, revision: payload.identity.revision, logicalTime: 1,
            size: 14, createdAt: now, updatedAt: now, accessedAt: now)))
        let store = try VaultFileSyncPayloadStore(
            rootURL: directory.url.appendingPathComponent("sync"), vaultID: "default",
            repository: repository,
            rootKey: { _ in try VaultRootKey(version: 1, key: Data(repeating: 7, count: 32)) })
        try await store.stageUpload(payload)
        try await store.installDownloadedPayload(payload)
        XCTAssertEqual(try repository.readContent(for: objectID), Data("linked-content".utf8))
        let stagedBeforeDelete = try await store.uploadPayload(for: payload.identity)
        XCTAssertNotNil(stagedBeforeDelete)
        try await store.removeAllPayloads(for: payload.identity)
        XCTAssertNil(try repository.readContent(for: objectID))
        let stagedAfterDelete = try await store.uploadPayload(for: payload.identity)
        XCTAssertNil(stagedAfterDelete)
    }

    func testTombstoneCancelsScopedTransferJobs() throws {
        let directory = try VaultTemporaryDirectory(name: "tombstone-jobs")
        let repository = try VaultRepository(testContainerURL: directory.url)
        let now = Date(timeIntervalSinceReferenceDate: 500)
        let revision = UUID()
        XCTAssertTrue(try repository.upsert(VaultObjectRecord(
            id: objectID, revision: revision, logicalTime: 1, size: 1,
            createdAt: now, updatedAt: now, accessedAt: now)))
        for kind in [VaultJobKind.upload, .download, .delete] {
            try repository.enqueue(VaultJob(
                kind: kind, objectID: objectID, state: .retrying,
                nextAttemptAt: now.addingTimeInterval(100), createdAt: now,
                updatedAt: now, idempotencyKey: kind.rawValue))
        }
        XCTAssertTrue(try repository.tombstone(VaultTombstone(
            id: objectID, revision: UUID(), logicalTime: 2,
            deletedAt: now.addingTimeInterval(1))))
        XCTAssertTrue(try repository.jobs().allSatisfy { $0.state == .cancelled })
    }

    func testProviderWakeRunsPersistedRetryWithoutRestaging() async throws {
        let directory = try VaultTemporaryDirectory(name: "retry-runner")
        let repository = try VaultRepository(testContainerURL: directory.url)
        let ubiquity = InMemoryVaultUbiquitousCoordinator()
        ubiquity.uploadRemainsPending = true
        let sync = VaultSyncCoordinator(
            repository: repository, backend: makeICloud(coordinator: ubiquity),
            payloadSource: InMemoryVaultSyncPayloadStore(), owner: "runner",
            configuration: VaultSyncConfiguration(location: .iCloud, initialBackoff: 30))
        let payload = try makePayload("resume", revision: UUID(), seed: 47)
        let initial = try await sync.upload(payload)
        XCTAssertEqual(initial.state, .retrying)
        let job = try XCTUnwrap(repository.jobs().first)
        XCTAssertEqual(job.objectID, payload.identity.objectID)
        XCTAssertEqual(job.remoteObjectKind, payload.identity.kind.rawValue)
        ubiquity.uploadRemainsPending = false
        let results = await sync.runReadyJobs(wakeReason: .providerStateChanged)
        XCTAssertEqual(results.first?.state, .succeeded)
        XCTAssertEqual(try repository.job(job.id)?.state, .succeeded)
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
        _ = try await syncA.upload(first)
        _ = try await syncA.upload(generation, expectedRemoteRevision: first.identity.revision)
        _ = try await syncA.upload(revisionTwo, expectedRemoteRevision: revision)
        _ = try await syncB.upload(first)
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

    private func verified(_ payload: VaultAuthenticatedCiphertext) throws -> VaultVerifiedCiphertext {
        try payload.verified { version in
            guard version == 1 else { throw VaultCryptoError.missingRootKey }
            return try VaultRootKey(version: 1, key: Data(repeating: 7, count: 32))
        }
    }
}

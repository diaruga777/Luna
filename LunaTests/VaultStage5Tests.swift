import Foundation
import CryptoKit
import XCTest
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultEmbeddings
import LunaVaultModels
import LunaVaultSearch
import LunaVaultSetup
import LunaVaultStorage
import LunaVaultUI
import VaultTestKit

final class VaultStage5Tests: XCTestCase {
    private struct TestProtection: VaultFileProtectionApplying {
        func apply(to url: URL) throws {}
        func hasRequiredProtection(at url: URL) throws -> Bool { true }
    }

    private final class Identity: VaultImportIdentityGenerating, @unchecked Sendable {
        let objectID: VaultObjectID
        let revision: UUID
        init() {
            objectID = VaultObjectID(rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
            revision = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        }
        func nextObjectID() -> VaultObjectID { objectID }
        func nextRevision() -> UUID { revision }
        func nextLogicalTime(now: Date) -> Int64 { 42 }
    }

    func testImportWritesProtectedOpaqueObjectAndDurableIndexJob() throws {
        let directory = try VaultTemporaryDirectory(name: "stage5-import")
        defer { try? directory.cleanUp() }
        let protection = TestProtection()
        let repository = try VaultRepository(testContainerURL: directory.url,
                                              protectionApplier: protection)
        let source = directory.url.appendingPathComponent("fixture.md")
        try Data("# Private note\nhello vault".utf8).write(to: source)
        let coordinator = try VaultImportCoordinator(
            repository: repository,
            configuration: VaultImportConfiguration(deviceID: "test", modelVersion: "fixture"),
            identity: Identity(), protectionApplier: protection)
        let result = try coordinator.importFile(VaultImportSource(fileURL: source, contentType: "text/markdown"),
                                                now: Date(timeIntervalSinceReferenceDate: 100))
        XCTAssertEqual(result.objectID.rawValue.uuidString, "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        XCTAssertEqual(try repository.readContent(for: result.objectID), Data("# Private note\nhello vault".utf8))
        XCTAssertTrue(try repository.jobs().contains { $0.kind == .index && $0.objectID == result.objectID })
        let contentDirectory = repository.contentDirectory.appendingPathComponent(result.objectID.rawValue.uuidString)
        XCTAssertFalse(contentDirectory.lastPathComponent.contains("fixture"))
    }

    func testIdenticalImportDeduplicatesContentAddressedObject() throws {
        let directory = try VaultTemporaryDirectory(name: "stage5-import-dedupe")
        defer { try? directory.cleanUp() }
        let protection = TestProtection()
        let repository = try VaultRepository(testContainerURL: directory.url,
                                              protectionApplier: protection)
        let source = directory.url.appendingPathComponent("fixture.txt")
        try Data("same bytes".utf8).write(to: source)
        let coordinator = try VaultImportCoordinator(repository: repository,
                                                      protectionApplier: protection)
        let first = try coordinator.importFile(VaultImportSource(fileURL: source,
                                                                  fileName: "first.txt"))
        let second = try coordinator.importFile(VaultImportSource(fileURL: source,
                                                                   fileName: "second.txt"))
        XCTAssertEqual(first.objectID, second.objectID)
        XCTAssertEqual(first.revision, second.revision)
        XCTAssertEqual(try repository.objects().count, 1)
        XCTAssertEqual(try repository.jobs().filter { $0.kind == .index }.count, 1)
    }

    func testIdenticalICloudImportAfterSuccessfulUploadIsIdempotent() throws {
        try assertRemoteDuplicateIsIdempotent(backendKey: "icloud:default")
    }

    func testIdenticalMacImportAfterSuccessfulUploadIsIdempotent() throws {
        try assertRemoteDuplicateIsIdempotent(backendKey: "mac:paired")
    }

    /// A completed upload is the reconciliation record for a content-addressed
    /// object. Replaying the same bytes must not reseal them with a fresh
    /// generation, enqueue a second upload, or leave an orphaned upload file.
    private func assertRemoteDuplicateIsIdempotent(backendKey: String) throws {
        let directory = try VaultTemporaryDirectory(name: "stage5-remote-dedupe")
        defer { try? directory.cleanUp() }
        let protection = TestProtection()
        let repository = try VaultRepository(testContainerURL: directory.url,
                                              protectionApplier: protection)
        let source = directory.url.appendingPathComponent("fixture.txt")
        let bytes = Data("remote duplicate bytes".utf8)
        try bytes.write(to: source)
        let remoteRoot = try VaultRootKey(version: 1, key: Data(repeating: 9, count: 32))
        let uploadDirectory = directory.url.appendingPathComponent("uploads", isDirectory: true)
        let remote = VaultImportRemoteConfiguration(
            backendKey: backendKey, vaultID: "stage5",
            root: remoteRoot, rootKey: { version in
                guard version == remoteRoot.version else { throw VaultCryptoError.missingRootKey }
                return remoteRoot
            }, payloadDirectory: uploadDirectory)
        let coordinator = try VaultImportCoordinator(
            repository: repository,
            configuration: VaultImportConfiguration(deviceID: "test", modelVersion: "fixture",
                                                     uploadBackendKey: backendKey, remote: remote),
            protectionApplier: protection)

        let first = try coordinator.importFile(VaultImportSource(fileURL: source),
                                                now: Date(timeIntervalSinceReferenceDate: 100))
        let firstUpload = try XCTUnwrap(first.uploadJobID.flatMap { try? repository.job($0) })
        let firstGeneration = try XCTUnwrap(firstUpload.payloadGeneration)
        let firstPayload = uploadDirectory.appendingPathComponent(
            ["content", first.objectID.rawValue.uuidString, first.revision.uuidString,
             firstGeneration].joined(separator: "-") + ".vault")
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstPayload.path))

        let claimed = try XCTUnwrap(try repository.claimJob(id: firstUpload.id,
                                                              owner: "test",
                                                              now: Date(timeIntervalSinceReferenceDate: 101)))
        try repository.transitionJob(id: claimed.id, leaseToken: claimed.leaseToken,
                                     state: .succeeded,
                                     now: Date(timeIntervalSinceReferenceDate: 102))
        // A real sync worker removes the upload payload once the provider has
        // acknowledged it. Keep only the durable succeeded job for replay.
        try VaultSecureFileAccess.removeRegularFile(at: firstPayload)

        let second = try coordinator.importFile(VaultImportSource(fileURL: source,
                                                                    fileName: "renamed.txt"),
                                                 now: Date(timeIntervalSinceReferenceDate: 103))
        XCTAssertEqual(second.objectID, first.objectID)
        XCTAssertEqual(second.revision, first.revision)
        XCTAssertEqual(second.uploadJobID, first.uploadJobID)
        XCTAssertEqual(try repository.objects().count, 1)
        let uploadJobs = try repository.jobs().filter { $0.kind == .upload }
        XCTAssertEqual(uploadJobs.count, 1)
        XCTAssertEqual(uploadJobs.first?.state, .succeeded)
        XCTAssertEqual(uploadJobs.first?.payloadGeneration, firstGeneration)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: uploadDirectory,
                                                                    includingPropertiesForKeys: nil)
            .isEmpty, "a successful duplicate must not leave a resealed payload")
        let stagingFiles = try FileManager.default.contentsOfDirectory(
            at: coordinator.stagingDirectory, includingPropertiesForKeys: nil)
        XCTAssertTrue(stagingFiles.isEmpty, "duplicate replay left staged/orphan files")
    }

    func testLocalIndexWorkerConsumesJobWithoutRemoteAccess() async throws {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("luna-vault-stage5-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let protection = TestProtection()
        let repository = try VaultRepository(testContainerURL: directory,
                                              protectionApplier: protection)
        let source = directory.appendingPathComponent("fixture.txt")
        try Data("searchable local phrase".utf8).write(to: source)
        let imported = try VaultImportCoordinator(repository: repository, identity: Identity(),
                                                  protectionApplier: protection)
            .importFile(VaultImportSource(fileURL: source, contentType: "text/plain"))
        let metadata = try VaultImportedFileMetadataStore(
            rootURL: directory.appendingPathComponent("metadata"),
            protectionApplier: protection)
        // The coordinator's protected metadata is its source of truth; copy a
        // deterministic descriptor into this injected store for the worker.
        let sourceMetadata = try VaultImportedFileMetadataStore(
            rootURL: repository.contentDirectory.deletingLastPathComponent()
                .appendingPathComponent("VaultImportStaging/Metadata"),
            protectionApplier: protection)
        try metadata.put(try XCTUnwrap(sourceMetadata.metadata(objectID: imported.objectID,
                                                               revision: imported.revision)))
        let index = try VaultSearchIndex(databaseURL: directory.appendingPathComponent("search.sqlite"),
                                         protectionApplier: protection)
        let worker = VaultIndexWorker(repository: repository, metadataStore: metadata,
                                      searchIndex: index,
                                      embeddings: DeterministicVaultEmbeddingGenerator(), owner: "test")
        let workTask = Task { [directory] in
            _ = directory
            return await worker.processNext()
        }
        let workOptional = await workTask.value
        _ = directory
        let work = try XCTUnwrap(workOptional)
        XCTAssertEqual(work.state, .indexed)
        XCTAssertEqual(try index.search("searchable").first?.objectID, imported.objectID)
        XCTAssertTrue(try repository.jobs().contains { $0.id == work.jobID && $0.state == .succeeded })

        let missingID = VaultObjectID(rawValue: UUID())
        let missingRevision = UUID()
        let missingNow = Date()
        try repository.upsert(VaultObjectRecord(id: missingID, revision: missingRevision,
                                                logicalTime: 2, size: 7,
                                                contentType: "text/plain", createdAt: missingNow,
                                                updatedAt: missingNow, accessedAt: missingNow,
                                                deviceID: "test"))
        try metadata.put(VaultImportedFileMetadata(objectID: missingID, revision: missingRevision,
                                                   fileName: "missing.txt", contentType: "text/plain",
                                                   byteCount: 7, createdAt: missingNow,
                                                   updatedAt: missingNow))
        try repository.setObjectReady(missingID)
        let missingJob = VaultJob(kind: .index, objectID: missingID,
                                  createdAt: missingNow, updatedAt: missingNow,
                                  idempotencyKey: "missing-content", revision: missingRevision)
        try repository.enqueue(missingJob)
        let missingTask = Task { [directory] in
            _ = directory
            return await worker.processNext(now: missingNow)
        }
        let missingOptional = await missingTask.value
        _ = directory
        let missing = try XCTUnwrap(missingOptional)
        XCTAssertEqual(missing.state, .downloadNeeded)
        XCTAssertEqual(try repository.job(missing.jobID!).map(\.state), .retrying)

        let generation = repository.contentDirectory
            .appendingPathComponent(imported.objectID.rawValue.uuidString)
            .appendingPathComponent(".content-generation")
        try Data("\(imported.revision.uuidString):\(String(repeating: "c", count: 64)):\(String(repeating: "d", count: 64))".utf8)
            .write(to: generation)
        let wrongJob = VaultJob(kind: .index, objectID: imported.objectID,
                                createdAt: missingNow, updatedAt: missingNow,
                                idempotencyKey: "wrong-generation", revision: imported.revision)
        try repository.enqueue(wrongJob)
        let wrongTask = Task { [directory] in
            _ = directory
            return await worker.processNext(now: missingNow.addingTimeInterval(62))
        }
        let wrongOptional = await wrongTask.value
        _ = directory
        let wrong = try XCTUnwrap(wrongOptional)
        XCTAssertEqual(wrong.state, .downloadNeeded)
        XCTAssertEqual(try repository.job(wrongJob.id)?.state, .retrying)
    }

    func testThumbnailGenerationIsIndependentAndEvictsByAge() throws {
        let directory = try VaultTemporaryDirectory(name: "stage5-thumbnail")
        defer { try? directory.cleanUp() }
        let protection = TestProtection()
        let store = try VaultThumbnailStore(
            rootURL: directory.url.appendingPathComponent("thumbs"),
            configuration: VaultThumbnailConfiguration(quotaBytes: 100, expiry: 10),
            protectionApplier: protection)
        let objectID = VaultObjectID(rawValue: UUID())
        let revision = UUID()
        let old = VaultThumbnailKey(objectID: objectID, revision: revision, generation: String(repeating: "a", count: 64))
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let oldDate = now.addingTimeInterval(-20)
        try store.put(Data([1, 2, 3]), for: old, now: oldDate)
        XCTAssertEqual(try store.data(for: old, now: oldDate), Data([1, 2, 3]))
        try store.evictExpired(now: now)
        XCTAssertNil(try store.data(for: old, now: now))
    }

    func testCacheCoordinatorTouchesAccessAndAppliesSevenDayExpiry() throws {
        let directory = try VaultTemporaryDirectory(name: "stage5-cache")
        defer { try? directory.cleanUp() }
        let repository = try VaultRepository(
            configuration: VaultStorageConfiguration(
                policy: VaultStoragePolicy(location: .iCloud, keepLocalCopy: false)),
            testContainerURL: directory.url,
            protectionApplier: TestProtection())
        let cache = VaultCacheCoordinator(repository: repository)
        let objectID = VaultObjectID(rawValue: UUID())
        let initial = Date(timeIntervalSinceReferenceDate: 20_000)
        try repository.upsert(VaultObjectRecord(id: objectID, revision: UUID(), logicalTime: 1,
                                                size: 12, createdAt: initial, updatedAt: initial,
                                                accessedAt: initial, deviceID: "test"))
        try cache.markAccessed(objectID, byteCount: 12, now: initial)
        XCTAssertEqual(try cache.status().fullContentBytes, 12)
        try cache.markAccessed(objectID, byteCount: 12, now: initial.addingTimeInterval(1))
        XCTAssertEqual(try repository.cacheEntries().first?.lastAccessedAt,
                       initial.addingTimeInterval(1))
        try cache.evict(now: initial.addingTimeInterval(7 * 86_400 + 2))
        XCTAssertEqual(try cache.status().entryCount, 0)
    }

    func testPreviewReportsDownloadNeededWithoutExposingRemoteURL() async throws {
        let directory = try VaultTemporaryDirectory(name: "stage5-preview")
        defer { try? directory.cleanUp() }
        let repository = try VaultRepository(testContainerURL: directory.url)
        let objectID = VaultObjectID(rawValue: UUID())
        let revision = UUID()
        let record = VaultObjectRecord(id: objectID, revision: revision, logicalTime: 1,
                                       size: 4, contentType: "video/mp4",
                                       createdAt: Date(), updatedAt: Date(), accessedAt: Date(),
                                       deviceID: "test")
        try repository.upsert(record)
        let identity = try VaultRemoteObjectIdentity(objectID: objectID, revision: revision,
                                                     kind: .content,
                                                     generation: String(repeating: "a", count: 64))
        let plan = try await VaultPreviewRouter(repository: repository)
            .plan(objectID: objectID, remoteIdentity: identity)
        XCTAssertEqual(plan.availability, VaultPreviewAvailability.needsDownload)
        XCTAssertNil(plan.localURL)
    }

    func testPreviewDownloadUsesCompleteLocalBytesBeforePlayback() async throws {
        let directory = try VaultTemporaryDirectory(name: "stage5-download")
        defer { try? directory.cleanUp() }
        let protection = TestProtection()
        let repository = try VaultRepository(testContainerURL: directory.url,
                                              protectionApplier: protection)
        let objectID = VaultObjectID(rawValue: UUID())
        let revision = UUID()
        let record = VaultObjectRecord(id: objectID, revision: revision, logicalTime: 1,
                                       size: 4, contentType: "video/mp4",
                                       createdAt: Date(), updatedAt: Date(), accessedAt: Date(),
                                       deviceID: "test")
        try repository.upsert(record)
        let generation = SHA256.hash(data: Data("full".utf8)).map { String(format: "%02x", $0) }.joined()
        let identity = try VaultRemoteObjectIdentity(objectID: objectID, revision: revision,
                                                     kind: .content, generation: generation)
        final class Downloader: VaultPreviewDownloadResultProviding, @unchecked Sendable {
            let repository: VaultRepository
            init(repository: VaultRepository) { self.repository = repository }
            func requestDownload(for identity: VaultRemoteObjectIdentity) async throws {
                _ = try await requestDownloadResult(for: identity)
            }
            func requestDownloadResult(for identity: VaultRemoteObjectIdentity) async throws -> VaultLocalContentCapability {
                _ = try repository.writeContent(Data("full".utf8), for: identity.objectID)
                guard let capability = try repository.localContentCapability(for: identity.objectID) else {
                    throw VaultPreviewError.downloadUnavailable
                }
                return capability
            }
        }
        let router = VaultPreviewRouter(repository: repository,
                                        downloadRequester: Downloader(repository: repository),
                                        protectionApplier: protection)
        let plan = try await router.downloadAndPlan(objectID: objectID, identity: identity)
        XCTAssertEqual(plan.availability, VaultPreviewAvailability.ready)
        XCTAssertEqual(plan.kind, .video)
        XCTAssertNotNil(plan.localURL)
        let lease = try repository.beginPreviewLease(try XCTUnwrap(plan.capability), duration: 5,
                                                      now: Date(timeIntervalSinceReferenceDate: 100))
        let renewed = try repository.renewPreviewLease(lease, duration: 30,
                                                        now: Date(timeIntervalSinceReferenceDate: 102))
        XCTAssertTrue(try repository.isPreviewActive(objectID, now: Date(timeIntervalSinceReferenceDate: 102)))
        try repository.endPreviewLease(lease)
        XCTAssertTrue(try repository.isPreviewActive(objectID, now: Date(timeIntervalSinceReferenceDate: 102)), "old token must not end renewed lease")
        try repository.endPreviewLease(renewed)
        XCTAssertFalse(try repository.isPreviewActive(objectID, now: Date(timeIntervalSinceReferenceDate: 102)))
        let wrongIdentity = try VaultRemoteObjectIdentity(objectID: objectID, revision: revision,
                                                           kind: .content,
                                                           generation: String(repeating: "c", count: 64))
        let wrongPlan = try await router.plan(objectID: objectID, remoteIdentity: wrongIdentity)
        XCTAssertEqual(wrongPlan.availability, VaultPreviewAvailability.needsDownload)
    }

    func testBackgroundSchedulerCancellationCancelsInjectedOperation() async throws {
        final class Submitter: VaultBackgroundTaskSubmitting, @unchecked Sendable {
            var cancelled = false
            func submit(identifier: String, requiresNetworkConnectivity: Bool,
                        requiresExternalPower: Bool, earliestBeginDate: Date?) throws {}
            func cancel(identifier: String) { cancelled = true }
        }
        let submitter = Submitter()
        let scheduler = VaultBackgroundTaskScheduler(identifierPrefix: "test.vault", submitter: submitter)
        scheduler.register(kind: .index) {
            while !Task.isCancelled { await Task.yield() }
            return false
        }
        let task = try scheduler.schedule(kind: .index, earliestBeginDate: nil)
        scheduler.cancel(kind: .index)
        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertTrue(submitter.cancelled)
    }
}

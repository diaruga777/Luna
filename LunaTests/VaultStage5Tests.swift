import Foundation
import XCTest
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

    func testLocalIndexWorkerConsumesJobWithoutRemoteAccess() async throws {
        let directory = try VaultTemporaryDirectory(name: "stage5-index")
        defer { try? directory.cleanUp() }
        let protection = TestProtection()
        let repository = try VaultRepository(testContainerURL: directory.url,
                                              protectionApplier: protection)
        let source = directory.url.appendingPathComponent("fixture.txt")
        try Data("searchable local phrase".utf8).write(to: source)
        let imported = try VaultImportCoordinator(repository: repository, identity: Identity(),
                                                  protectionApplier: protection)
            .importFile(VaultImportSource(fileURL: source, contentType: "text/plain"))
        let metadata = try VaultImportedFileMetadataStore(
            rootURL: directory.url.appendingPathComponent("metadata"))
        // The coordinator's protected metadata is its source of truth; copy a
        // deterministic descriptor into this injected store for the worker.
        let sourceMetadata = try VaultImportedFileMetadataStore(
            rootURL: repository.contentDirectory.deletingLastPathComponent()
                .appendingPathComponent("VaultImportStaging/Metadata"))
        try metadata.put(try XCTUnwrap(sourceMetadata.metadata(objectID: imported.objectID,
                                                               revision: imported.revision)))
        let index = try VaultSearchIndex(databaseURL: directory.url.appendingPathComponent("search.sqlite"))
        let worker = VaultIndexWorker(repository: repository, metadataStore: metadata,
                                      searchIndex: index,
                                      embeddings: DeterministicVaultEmbeddingGenerator(), owner: "test")
        let workOptional = await worker.processNext()
        let work = try XCTUnwrap(workOptional)
        XCTAssertEqual(work.state, .indexed)
        XCTAssertEqual(try index.search("searchable").first?.objectID, imported.objectID)
        XCTAssertTrue(try repository.jobs().contains { $0.id == work.jobID && $0.state == .succeeded })
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
        let repository = try VaultRepository(testContainerURL: directory.url,
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
        let identity = try VaultRemoteObjectIdentity(objectID: objectID, revision: revision,
                                                     kind: .content,
                                                     generation: String(repeating: "b", count: 64))
        final class Downloader: VaultPreviewDownloadRequesting, @unchecked Sendable {
            let repository: VaultRepository
            init(repository: VaultRepository) { self.repository = repository }
            func requestDownload(for identity: VaultRemoteObjectIdentity) async throws {
                try repository.writeContent(Data("full".utf8), for: identity.objectID)
            }
        }
        let router = VaultPreviewRouter(repository: repository,
                                        downloadRequester: Downloader(repository: repository),
                                        protectionApplier: protection)
        let plan = try await router.downloadAndPlan(objectID: objectID, identity: identity)
        XCTAssertEqual(plan.availability, VaultPreviewAvailability.ready)
        XCTAssertEqual(plan.kind, .video)
        XCTAssertNotNil(plan.localURL)
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

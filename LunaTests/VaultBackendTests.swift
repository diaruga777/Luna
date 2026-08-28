import Foundation
import LunaVaultBackend
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
        XCTAssertFalse(backend.capabilities.requiresClientSideEncryption)
        XCTAssertTrue(backend.capabilities.supportsAtomicWrites)
        try await backend.putCiphertext(Data("hello device".utf8), for: objectID)
        let range = try await backend.ciphertext(for: objectID, range: 0..<5)
        let full = try await backend.ciphertext(for: objectID)
        XCTAssertEqual(range, Data("hello".utf8))
        XCTAssertEqual(full, Data("hello device".utf8))
        XCTAssertEqual(try repository.readContent(for: objectID), Data("hello device".utf8))
    }

    func testICloudBackendOnlyStoresOpaqueCiphertextAndUsesOpaquePaths() async throws {
        let coordinator = InMemoryVaultUbiquitousCoordinator()
        let backend = VaultICloudBackend(configuration: VaultICloudBackendConfiguration(
            containerIdentifier: "iCloud.com.example.vault", retryPolicy: VaultBackendRetryPolicy(maximumAttempts: 1)),
                                         coordinator: coordinator)
        let plaintext = Data("never send this plaintext".utf8)
        let ciphertext = Data([0x01, 0x99, 0xab, 0xcd])
        try await backend.putCiphertext(ciphertext, for: objectID)
        let stored = try await backend.ciphertext(for: objectID)
        XCTAssertEqual(stored, ciphertext)
        XCTAssertNil(coordinator.bytes(at: "plaintext"))
        XCTAssertNotEqual(stored, plaintext)
        XCTAssertTrue(backend.capabilities.requiresClientSideEncryption)
        XCTAssertTrue(backend.capabilities.supportsAtomicWrites)
        XCTAssertFalse(backend.capabilities.supportsRangeReads)
    }

    func testICloudEvictionNeverClaimsSuccessBeforeSystemConfirmsIt() async throws {
        let coordinator = InMemoryVaultUbiquitousCoordinator()
        let backend = VaultICloudBackend(configuration: VaultICloudBackendConfiguration(
            containerIdentifier: "iCloud.example", keepLocalCopy: true), coordinator: coordinator)
        try await backend.putCiphertext(Data([1, 2, 3]), for: objectID)
        coordinator.evictionRemainsPending = true
        let pending = try await backend.evictionOutcome(for: objectID)
        XCTAssertEqual(pending, .pending)
        XCTAssertTrue(try coordinator.state(for: "VaultObjects/default/\(objectID.rawValue.uuidString).vault").isDownloaded)
        coordinator.evictionRemainsPending = false
        let evicted = try await backend.evictionOutcome(for: objectID)
        XCTAssertEqual(evicted, .evicted)
        XCTAssertFalse(try coordinator.state(for: "VaultObjects/default/\(objectID.rawValue.uuidString).vault").isDownloaded)
    }

    func testUnavailableICloudDoesNotFallBackToLocalDirectory() async throws {
        let coordinator = InMemoryVaultUbiquitousCoordinator(rootURL: nil)
        let backend = VaultICloudBackend(configuration: VaultICloudBackendConfiguration(containerIdentifier: "iCloud.example"), coordinator: coordinator)
        XCTAssertEqual(backend.capabilities.availability, .unavailable)
        do {
            try await backend.putCiphertext(Data([1]), for: objectID)
            XCTFail("unavailable iCloud unexpectedly accepted a write")
        } catch let error as VaultBackendError {
            XCTAssertEqual(error, .unavailable)
        }
    }

    func testDurableSyncClaimsExactOperationAndReplaysIdempotently() async throws {
        let directory = try VaultTemporaryDirectory(name: "sync-backend")
        let repository = try VaultRepository(testContainerURL: directory.url)
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let record = VaultObjectRecord(id: objectID, revision: UUID(), logicalTime: 1,
                                       size: 3, createdAt: now, updatedAt: now, accessedAt: now)
        XCTAssertTrue(try repository.upsert(record))
        let payload = Data([0x80, 0x81, 0x82])
        let source = TestSyncPayloadSource(upload: payload)
        let backend = InMemoryVaultBackend()
        let coordinator = VaultSyncCoordinator(repository: repository, backend: backend,
                                               payloadSource: source, owner: "test-worker")
        let result = try await coordinator.upload(objectID, now: now)
        XCTAssertEqual(result.state, .succeeded)
        let uploaded = try await backend.ciphertext(for: objectID)
        XCTAssertEqual(uploaded, payload)
        // The durable idempotency row makes a second call a no-op rather than
        // enqueueing a second object operation.
        let replay = try await coordinator.upload(objectID, now: now.addingTimeInterval(1))
        XCTAssertEqual(replay.state, .succeeded)
        XCTAssertEqual(replay.attempts, result.attempts)
        XCTAssertEqual(source.uploadCalls, 1)
    }
}

private final class TestSyncPayloadSource: VaultSyncPayloadSource, @unchecked Sendable {
    private let lock = NSLock()
    private let uploadValue: Data
    private var uploads = 0
    init(upload: Data) { uploadValue = upload }
    func uploadPayload(for id: VaultObjectID) async throws -> Data? {
        lock.withLock { uploads += 1 }
        return uploadValue
    }
    func saveDownloadedPayload(_ payload: Data, for id: VaultObjectID) async throws {}
    var uploadCalls: Int { lock.withLock { uploads } }
}

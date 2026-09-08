import Foundation
import LunaVaultModels
import LunaVaultStorage
import VaultTestKit
import XCTest

/// Regression pins for the 2026-08-31 storage review pass: a retried
/// `insertAtomically` must republish the ready bit even when the content
/// write itself is skipped as already-installed, a winning revision must
/// clear a stale ready bit, a replay must not silently keep changed bytes
/// under the same (objectID, revision) key, and the thumbnail cache must not
/// let one generation's removal delete a sibling generation's payload.
final class VaultStorageReviewFixTests: XCTestCase {
    private let objectID = VaultObjectID(rawValue: UUID(uuidString: "44444444-5555-6666-7777-888888888888")!)
    private let revision = UUID(uuidString: "12121212-3434-5656-7878-909090909090")!

    func testRetriedInsertAtomicallyRepublishesReadyBitWhenContentAlreadyInstalled() throws {
        let directory = try VaultTemporaryDirectory(name: "insert-replay-ready")
        defer { try? directory.cleanUp() }
        let repository = try VaultRepository(testContainerURL: directory.url)
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let record = VaultObjectRecord(id: objectID, revision: revision, logicalTime: 1, size: 4,
                                       createdAt: now, updatedAt: now, accessedAt: now, deviceID: "phone")
        // Simulate a crash after content installed but before the ready bit
        // committed: install the object row and its content directly with
        // visibility withheld, bypassing insertAtomically's own ready call.
        XCTAssertTrue(try repository.upsert(record))
        _ = try repository.writeContent(Data("data".utf8), for: objectID, visibility: false)
        XCTAssertFalse(try repository.objectIsReady(objectID),
                       "content is installed but never published, as if the process died first")

        let retry = VaultAtomicObjectInsertRequest(record: record, content: Data("data".utf8))
        XCTAssertTrue(try repository.insertAtomically(retry))

        XCTAssertTrue(try repository.objectIsReady(objectID),
                      "a retry that finds content already installed must still publish the ready bit")
    }

    func testUpsertToNewRevisionClearsStaleReadyBit() throws {
        let directory = try VaultTemporaryDirectory(name: "upsert-clears-ready")
        defer { try? directory.cleanUp() }
        let repository = try VaultRepository(testContainerURL: directory.url)
        let now = Date(timeIntervalSinceReferenceDate: 2_000)
        let record = VaultObjectRecord(id: objectID, revision: revision, logicalTime: 1, size: 3,
                                       createdAt: now, updatedAt: now, accessedAt: now, deviceID: "phone")
        XCTAssertTrue(try repository.upsert(record))
        _ = try repository.writeContent(Data("old".utf8), for: objectID)
        XCTAssertTrue(try repository.objectIsReady(objectID))

        let newRevision = VaultObjectRecord(id: objectID, revision: UUID(), logicalTime: 2, size: 3,
                                            createdAt: now, updatedAt: now, accessedAt: now, deviceID: "phone")
        XCTAssertTrue(try repository.upsert(newRevision))

        XCTAssertFalse(try repository.objectIsReady(objectID),
                       "a worker must not claim jobs for the new revision against the old revision's payload")
    }

    func testTombstoneClearsStaleReadyBit() throws {
        let directory = try VaultTemporaryDirectory(name: "tombstone-clears-ready")
        defer { try? directory.cleanUp() }
        let repository = try VaultRepository(testContainerURL: directory.url)
        let now = Date(timeIntervalSinceReferenceDate: 3_000)
        let record = VaultObjectRecord(id: objectID, revision: revision, logicalTime: 1, size: 3,
                                       createdAt: now, updatedAt: now, accessedAt: now, deviceID: "phone")
        XCTAssertTrue(try repository.upsert(record))
        _ = try repository.writeContent(Data("old".utf8), for: objectID)
        XCTAssertTrue(try repository.objectIsReady(objectID))

        XCTAssertTrue(try repository.tombstone(
            VaultTombstone(id: objectID, revision: UUID(), logicalTime: 2, deletedAt: now, deviceID: "phone")))

        XCTAssertFalse(try repository.objectIsReady(objectID))
    }

    func testInsertAtomicallyReplayRejectsChangedBodyForSameRevision() throws {
        let directory = try VaultTemporaryDirectory(name: "insert-replay-digest")
        defer { try? directory.cleanUp() }
        let repository = try VaultRepository(testContainerURL: directory.url)
        let now = Date(timeIntervalSinceReferenceDate: 4_000)
        let record = VaultObjectRecord(id: objectID, revision: revision, logicalTime: 1, size: 4,
                                       createdAt: now, updatedAt: now, accessedAt: now, deviceID: "phone")
        let first = VaultAtomicObjectInsertRequest(record: record, content: Data("old!".utf8))
        XCTAssertTrue(try repository.insertAtomically(first))

        // Same (objectID, revision) key, different bytes: a retry must never
        // silently keep the previously-installed bytes.
        let changed = VaultAtomicObjectInsertRequest(record: record, content: Data("new!".utf8))
        XCTAssertThrowsError(try repository.insertAtomically(changed))
        XCTAssertEqual(try repository.readContent(for: objectID), Data("old!".utf8),
                       "a rejected replay must not disturb the bytes already installed")
    }

    func testThumbnailRemovalScopedToOneGenerationLeavesSiblingReadable() throws {
        let directory = try VaultTemporaryDirectory(name: "thumbnail-sibling-generation")
        defer { try? directory.cleanUp() }
        let store = try VaultThumbnailStore(rootURL: directory.url.appendingPathComponent("thumbs"))
        let now = Date(timeIntervalSinceReferenceDate: 5_000)
        // Two generations of the same object revision share one on-disk
        // directory (keyed by objectID/revision); only their payload
        // filenames differ.
        let first = VaultThumbnailKey(objectID: objectID, revision: revision,
                                      generation: String(repeating: "a", count: 64))
        let second = VaultThumbnailKey(objectID: objectID, revision: revision,
                                       generation: String(repeating: "b", count: 64))
        try store.put(Data([1, 2, 3]), for: first, now: now)
        try store.put(Data([4, 5, 6]), for: second, now: now)

        try store.invalidate(first)

        XCTAssertNil(try store.data(for: first, now: now))
        XCTAssertEqual(try store.data(for: second, now: now), Data([4, 5, 6]),
                       "removing one generation must not delete a sibling generation sharing its directory")
    }
}

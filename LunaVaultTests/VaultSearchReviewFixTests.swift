//
//  VaultSearchReviewFixTests.swift
//  LunaTests
//
//  Regression pins for the 2026-08-31 Vault review's search-cluster fixes:
//  the transactional v2->v3 migration, the restore WAL/SHM cleanup, the
//  per-model embedding scope, the automatic-group cap, manual membership on
//  an automatic group, and the UTF-8 revision-stamp parity between the
//  single-document and bulk upsert paths.
//

import Foundation
import LunaVaultCrypto
import LunaVaultEmbeddings
import LunaVaultModels
import LunaVaultSearch
import LunaVaultIndexExtraction
import SQLite3
import VaultTestKit
import XCTest

final class VaultSearchReviewFixTests: XCTestCase {
    private func id(_ value: Int) -> VaultObjectID { VaultObjectID(rawValue: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!) }
    private func revision(_ value: Int) -> UUID { UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", value))! }
    private func doc(_ value: Int, filename: String = "file.txt", body: String = "", vector: [Float]? = nil, device: String = "phone") -> VaultIndexedDocument {
        let date = Date(timeIntervalSinceReferenceDate: TimeInterval(value))
        return VaultIndexedDocument(id: id(value), revision: revision(value), logicalTime: Int64(value), deviceID: device,
            filename: filename, bodyText: body, createdAt: date, updatedAt: date, accessedAt: date,
            embedding: vector.map { VaultEmbedding(values: $0, modelVersion: "v1") })
    }

    // MARK: - Transactional migration (v2 on-disk schema -> v3)

    /// Builds a genuinely shipped v2 database by hand (not via `VaultSearchIndex`
    /// itself), so this reproduces an existing user's on-disk file rather than a
    /// current database whose version stamp was merely lowered.
    private func createRawV2Database(at url: URL, documentID: VaultObjectID, filename: String, body: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "VaultSearchReviewFixTests.SQLite", code: 1)
        }
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE documents(id TEXT PRIMARY KEY,revision TEXT NOT NULL,logical_time INTEGER NOT NULL,device_id TEXT NOT NULL,filename TEXT NOT NULL,body TEXT NOT NULL,ocr TEXT NOT NULL,transcript TEXT NOT NULL,created_at REAL NOT NULL,updated_at REAL NOT NULL,accessed_at REAL NOT NULL,source TEXT NOT NULL,tombstone INTEGER NOT NULL CHECK(tombstone IN(0,1)));
        CREATE VIRTUAL TABLE vault_fts USING fts5(id UNINDEXED,filename,body,ocr,transcript);
        CREATE TABLE model_spaces(model_version TEXT PRIMARY KEY,dimension INTEGER NOT NULL CHECK(dimension>0));
        CREATE TABLE embeddings(object_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,model_version TEXT NOT NULL REFERENCES model_spaces(model_version),dimension INTEGER NOT NULL CHECK(dimension>0),"values" BLOB NOT NULL,PRIMARY KEY(object_id,model_version));
        CREATE TABLE groups(id TEXT PRIMARY KEY,label TEXT NOT NULL,frozen INTEGER NOT NULL CHECK(frozen IN(0,1)),automatic INTEGER NOT NULL CHECK(automatic IN(0,1)),created_at REAL NOT NULL,updated_at REAL NOT NULL,model_version TEXT,dimension INTEGER,centroid BLOB,member_count INTEGER NOT NULL DEFAULT 0 CHECK(member_count>=0));
        CREATE TABLE group_members(group_id TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,object_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,PRIMARY KEY(group_id,object_id));
        CREATE TABLE query_groups(id TEXT PRIMARY KEY,query TEXT NOT NULL,live INTEGER NOT NULL CHECK(live IN(0,1)),created_at REAL NOT NULL);
        CREATE TABLE query_group_members(group_id TEXT NOT NULL REFERENCES query_groups(id) ON DELETE CASCADE,object_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,PRIMARY KEY(group_id,object_id));
        CREATE TABLE aliases(id TEXT PRIMARY KEY,original_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,group_id TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,model_version TEXT NOT NULL REFERENCES model_spaces(model_version),dimension INTEGER NOT NULL CHECK(dimension>0),"values" BLOB NOT NULL,UNIQUE(original_id,group_id,model_version));
        CREATE INDEX embeddings_model ON embeddings(model_version);
        CREATE INDEX aliases_model ON aliases(model_version);
        INSERT INTO documents(id,revision,logical_time,device_id,filename,body,ocr,transcript,created_at,updated_at,accessed_at,source,tombstone)
            VALUES('\(documentID.rawValue.uuidString)','\(UUID().uuidString)',1,'phone','\(filename)','\(body)','','',0,0,0,'device',0);
        INSERT INTO vault_fts(id,filename,body,ocr,transcript) VALUES('\(documentID.rawValue.uuidString)','\(filename)','\(body)','','');
        PRAGMA user_version=2;
        """
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "fixture failed"
            sqlite3_free(errorMessage)
            throw NSError(domain: "VaultSearchReviewFixTests.SQLite", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    /// A crash mid-migration used to strand a half-created schema with a
    /// stale `user_version`, permanently bricking the index on reopen. Every
    /// migration step now commits with its `user_version` bump inside one
    /// transaction, so this only pins the READABLE side of that fix: opening
    /// a genuinely shipped v2 file must migrate cleanly, keep the existing
    /// row searchable, and support normal writes on the upgraded schema.
    func testExistingV2DatabaseMigratesCleanlyAndStaysSearchable() throws {
        let directory = try VaultTemporaryDirectory(name: "search-migrate-v2")
        let url = directory.url.appendingPathComponent("vault-index.sqlite")
        try createRawV2Database(at: url, documentID: id(1), filename: "legacy.txt", body: "legacy quarterly report")

        let index = try VaultSearchIndex(databaseURL: url)
        XCTAssertEqual(try index.search("quarterly").first?.objectID, id(1))
        XCTAssertEqual(try index.integrityCheck(), "ok")

        // Exercise the migrated fts_rowid column and the new indexes on a
        // normal write, not just a read.
        try index.upsert(doc(2, filename: "fresh.txt", body: "fresh content"))
        XCTAssertTrue(try index.delete(id(2), stamp: VaultIndexRevision(logicalTime: 99, deviceID: "phone")))
        XCTAssertTrue(try index.search("fresh").isEmpty)
        XCTAssertEqual(try index.search("quarterly").count, 1, "the pre-existing row survives the migration and further writes")

        // Reopening a second time replays `migrate()` against an
        // already-migrated schema; `CREATE INDEX IF NOT EXISTS` must not fail.
        let reopened = try VaultSearchIndex(databaseURL: url)
        XCTAssertEqual(try reopened.integrityCheck(), "ok")
    }

    // MARK: - Restore WAL/SHM cleanup

    /// Restore used to replace only the main database file, leaving any
    /// pre-existing `-wal`/`-shm` siblings from whatever database previously
    /// lived at that path — the next open would recover those stale frames
    /// onto the restored snapshot. Simulates the leftover siblings directly
    /// (SQLite checkpoints its OWN WAL on a clean close, so reproducing a
    /// non-empty stale WAL via a real prior connection is not deterministic);
    /// what the fix guarantees is that restore always clears both paths.
    func testRestoreRemovesStaleWALAndSHMSiblings() throws {
        let directory = try VaultTemporaryDirectory(name: "search-restore-wal")
        let destinationURL = directory.url.appendingPathComponent("vault-index.sqlite")
        try Data("stale main db from a prior incarnation".utf8).write(to: destinationURL)
        let walURL = URL(fileURLWithPath: destinationURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: destinationURL.path + "-shm")
        try Data("stale wal frames".utf8).write(to: walURL)
        try Data("stale shm index".utf8).write(to: shmURL)

        let sourceDirectory = try VaultTemporaryDirectory(name: "search-restore-wal-source")
        let source = try VaultSearchIndex(databaseURL: sourceDirectory.url.appendingPathComponent("index.sqlite"))
        try source.upsert(doc(2, filename: "restored.txt", body: "restored text"))
        let root = try VaultRootKey(version: 1, key: Data(repeating: 3, count: 32))
        let cryptor = VaultChunkedCryptor(vaultID: "restore-wal-tests", random: VaultTestRandomBytes(seed: 7))
        let artifact = try source.encryptedExport(cryptor: cryptor, root: root, objectID: id(500), revision: revision(500))

        try VaultSearchIndex.restoreEncryptedExport(artifact, cryptor: cryptor, to: destinationURL) { _ in root }

        XCTAssertFalse(FileManager.default.fileExists(atPath: walURL.path), "a stale WAL sibling must not survive a restore")
        XCTAssertFalse(FileManager.default.fileExists(atPath: shmURL.path), "a stale SHM sibling must not survive a restore")

        let reopened = try VaultSearchIndex(databaseURL: destinationURL)
        XCTAssertEqual(try reopened.integrityCheck(), "ok")
        XCTAssertEqual(try reopened.search("restored").count, 1)
    }

    // MARK: - Per-model embedding scope

    /// Re-indexing an object under a second model version used to delete
    /// EVERY model's embedding for that object, not just the incoming one.
    func testUpsertUnderASecondModelPreservesTheFirstModelsEmbedding() throws {
        let directory = try VaultTemporaryDirectory(name: "search-multi-model")
        let index = try VaultSearchIndex(databaseURL: directory.url.appendingPathComponent("index.sqlite"))
        let modelA = VaultEmbedding(values: [1, 0], modelVersion: "model-a")
        try index.upsert(VaultIndexedDocument(id: id(1), revision: revision(1), logicalTime: 1, deviceID: "phone",
            filename: "doc", createdAt: Date(), updatedAt: Date(), accessedAt: Date(), embedding: modelA))
        XCTAssertEqual(try index.cosineSearch(modelA).first?.0, id(1))

        let modelB = VaultEmbedding(values: [0, 1, 0], modelVersion: "model-b")
        try index.upsert(VaultIndexedDocument(id: id(1), revision: revision(2), logicalTime: 2, deviceID: "phone",
            filename: "doc", createdAt: Date(), updatedAt: Date(), accessedAt: Date(), embedding: modelB))

        XCTAssertEqual(try index.cosineSearch(modelB).first?.0, id(1), "the newly indexed model's vector is present")
        XCTAssertEqual(try index.cosineSearch(modelA).first?.0, id(1), "the earlier model's vector must survive re-indexing under a different model")
    }

    // MARK: - Automatic-group cap

    /// When every existing centroid is frozen, `ranked` is empty and the code
    /// used to mint a brand-new automatic group without consulting the cap.
    func testEvolveAutomaticGroupsRespectsCapWhenEveryCentroidIsFrozen() throws {
        let directory = try VaultTemporaryDirectory(name: "search-evolve-cap")
        let configuration = VaultSearchConfiguration(maximumAutomaticGroups: 1)
        let index = try VaultSearchIndex(databaseURL: directory.url.appendingPathComponent("index.sqlite"), configuration: configuration)
        try index.upsert(doc(1, filename: "a.jpg", vector: [1, 0]))
        let firstPass = try index.evolveAutomaticGroups(modelVersion: "v1", threshold: 0.9)
        XCTAssertEqual(firstPass.count, 1)
        try index.renameGroup(firstPass[0].id, label: firstPass[0].label, frozen: true)

        // A dissimilar candidate cannot join the one (frozen) group by score,
        // and the cap is already at its configured maximum of 1.
        try index.upsert(doc(2, filename: "b.jpg", vector: [0, 1]))
        let secondPass = try index.evolveAutomaticGroups(modelVersion: "v1", threshold: 0.9)
        XCTAssertEqual(secondPass.count, 1, "the automatic-group cap must hold even when every existing centroid is frozen")
    }

    // MARK: - Manual membership on an automatic group

    /// The UI allows adding a manual member to an automatic group
    /// (`VaultHomeViewController`); that call must keep working rather than
    /// being forbidden, per the review's chosen fix.
    func testAddManualMembershipSucceedsOnAnAutomaticGroup() throws {
        let directory = try VaultTemporaryDirectory(name: "search-manual-on-automatic")
        let index = try VaultSearchIndex(databaseURL: directory.url.appendingPathComponent("index.sqlite"))
        try index.upsert(doc(1, filename: "a.jpg", vector: [1, 0]))
        try index.upsert(doc(2, filename: "b.jpg", vector: [0, 1]))
        // Two orthogonal vectors under a near-1.0 threshold land in two
        // separate automatic groups; pick the one id(2) is not already in,
        // so the manual add below is a genuinely new membership.
        let groups = try index.evolveAutomaticGroups(modelVersion: "v1", threshold: 0.99)
        XCTAssertEqual(groups.count, 2)
        let targetGroup = try XCTUnwrap(groups.first { $0.automatic && !$0.memberIDs.contains(self.id(2)) })

        let alias = try index.addManualMembership(objectID: id(2), toGroup: targetGroup.id, modelVersion: "v1")
        XCTAssertEqual(alias.originalObjectID, id(2))
        let refreshed = try XCTUnwrap(try index.groups().first { $0.id == targetGroup.id })
        XCTAssertTrue(refreshed.memberIDs.contains(id(2)))
    }

    // MARK: - Revision-stamp UTF-8 parity

    /// SQLite's default BINARY collation orders TEXT by raw UTF-8 bytes;
    /// Swift's `String <` used Unicode canonical ordering instead. For a
    /// decomposed-vs-plain-ASCII device ID pair the two disagree on order,
    /// so the single-document path (Swift `<`) and the bulk path (SQL
    /// BINARY) could pick different winners for the same conflicting update.
    func testConflictResolutionAgreesBetweenSingleAndBulkPathsForNonASCIIDeviceIDs() throws {
        // Byte-for-byte: "e\u{0301}" encodes as 0x65 0xCC 0x81, "f" as 0x66,
        // so 0x65 < 0x66 puts the decomposed form first in UTF-8 byte order —
        // the order this test expects both paths to agree on.
        let earlierDevice = "e\u{0301}"
        let laterDevice = "f"
        XCTAssertTrue(earlierDevice.utf8.lexicographicallyPrecedes(laterDevice.utf8))

        func documentPair(_ objectID: VaultObjectID) -> (earlier: VaultIndexedDocument, later: VaultIndexedDocument) {
            let now = Date()
            let earlier = VaultIndexedDocument(id: objectID, revision: UUID(), logicalTime: 5, deviceID: earlierDevice,
                filename: "earlier", bodyText: "earlier body", createdAt: now, updatedAt: now, accessedAt: now)
            let later = VaultIndexedDocument(id: objectID, revision: UUID(), logicalTime: 5, deviceID: laterDevice,
                filename: "later", bodyText: "later body", createdAt: now, updatedAt: now, accessedAt: now)
            return (earlier, later)
        }

        // Single-document path (Swift comparator).
        let singleDirectory = try VaultTemporaryDirectory(name: "search-parity-single")
        let single = try VaultSearchIndex(databaseURL: singleDirectory.url.appendingPathComponent("index.sqlite"))
        let singlePair = documentPair(id(1))
        try single.upsert(singlePair.earlier)
        XCTAssertTrue(try single.upsert(singlePair.later), "the byte-later stamp must win under the single-document path")
        XCTAssertEqual(try single.document(id(1))?.filename, "later")

        // Bulk path (SQL BINARY comparator) — same pair, same expected winner.
        let bulkDirectory = try VaultTemporaryDirectory(name: "search-parity-bulk")
        let bulk = try VaultSearchIndex(databaseURL: bulkDirectory.url.appendingPathComponent("index.sqlite"))
        let bulkPair = documentPair(id(2))
        _ = try bulk.upsertBatch([bulkPair.earlier])
        _ = try bulk.upsertBatch([bulkPair.later])
        XCTAssertEqual(try bulk.document(id(2))?.filename, "later", "the bulk path's own SQL comparator agrees with the single-document path")
    }

    // MARK: - Archive preflight: compressed>0 && uncompressed==0

    /// An entry that claims zero uncompressed bytes while genuinely
    /// compressed passed every size/ratio limit, then drove `inflate`'s
    /// doubling search up to its per-entry ceiling for nothing.
    func testArchivePreflightRejectsNonEmptyCompressedStreamClaimingZeroUncompressedBytes() throws {
        let zip = zeroUncompressedZIPFixture()
        XCTAssertThrowsError(try VaultZIPArchivePreflight().validate(zip, policy: VaultExtractionPolicy())) { error in
            guard case let VaultExtractionError.unsafeArchive(message) = error else { return XCTFail("unexpected error: \(error)") }
            XCTAssertEqual(message, "uncompressed size")
        }
    }

    private func zeroUncompressedZIPFixture() -> Data {
        var data = Data()
        func u16(_ value: UInt16) { data.append(UInt8(value & 0xff)); data.append(UInt8(value >> 8)) }
        func u32(_ value: UInt32) { u16(UInt16(value & 0xffff)); u16(UInt16(value >> 16)) }
        let name = Data("entry.bin".utf8)
        u32(0x02014B50); u16(20); u16(20); u16(0); u16(8); u16(0); u16(0); u32(0)
        u32(64) /* compressed: non-zero */; u32(0) /* uncompressed: zero */
        u16(UInt16(name.count)); u16(0); u16(0); u16(0); u16(0); u32(0); u32(0)
        data.append(name)
        let centralSize = UInt32(data.count)
        u32(0x06054B50); u16(0); u16(0); u16(1); u16(1); u32(centralSize); u32(0); u16(0)
        return data
    }
}

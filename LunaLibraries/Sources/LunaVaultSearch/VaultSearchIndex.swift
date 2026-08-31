import Foundation
import SQLite3
import LunaVaultCrypto
import LunaVaultEmbeddings
import LunaVaultModels
import LunaVaultStorage

private let vaultSearchSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Performs the SQLite WAL checkpoint used before an encrypted export or a
/// maintenance truncation. Production always checkpoints the real database
/// handle; a test witness can return SQLITE_BUSY/SQLITE_ERROR to prove export
/// fails closed without a live lock contest.
public protocol VaultWALCheckpointing: Sendable {
    func checkpoint(database: OpaquePointer) -> Int32
}

public struct SystemVaultWALCheckpointing: VaultWALCheckpointing {
    public init() {}
    public func checkpoint(database: OpaquePointer) -> Int32 {
        sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    }
}

public final class VaultSearchIndex: @unchecked Sendable {
    public let databaseURL: URL
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.hsanabria.luna.vault.search.sqlite")
    private let configuration: VaultSearchConfiguration
    private let namer: VaultGroupNaming
    private let protection: VaultFileProtectionApplying
    private let walCheckpointing: any VaultWALCheckpointing

    public init(databaseURL: URL,
                configuration: VaultSearchConfiguration = VaultSearchConfiguration(),
                namer: VaultGroupNaming = KeywordVaultGroupNamer(),
                protectionApplier: VaultFileProtectionApplying = SystemVaultFileProtectionApplier(),
                walCheckpointing: any VaultWALCheckpointing = SystemVaultWALCheckpointing()) throws {
        guard (1...1_000).contains(configuration.maximumResults),
              configuration.maximumLexicalCandidates >= configuration.maximumResults,
              configuration.maximumLexicalCandidates <= 20_000,
              (1...10_000).contains(configuration.maximumAutomaticGroups) else {
            throw VaultSearchError.invalidLimit(configuration.maximumResults)
        }
        self.databaseURL = databaseURL; self.configuration = configuration
        self.namer = namer; protection = protectionApplier
        self.walCheckpointing = walCheckpointing
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try protection.apply(to: databaseURL.deletingLastPathComponent())
        var opened: OpaquePointer?
        let openStatus = sqlite3_open_v2(databaseURL.path, &opened,
                                         SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        // sqlite3_open_v2 can hand back a live (partially initialized) handle
        // even when it reports failure; SQLite's own contract requires
        // closing it either way to avoid leaking the connection.
        guard openStatus == SQLITE_OK, let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw VaultSearchError.sqlite("open")
        }
        db = opened
        do {
            sqlite3_busy_timeout(opened, 5_000)
            try sync {
                try retryBusy { try execute("PRAGMA journal_mode=WAL") }
                try execute("PRAGMA synchronous=FULL")
                try execute("PRAGMA foreign_keys=ON")
                try retryBusy { try migrate() }
            }
            try protectDatabaseFiles()
        } catch { sqlite3_close_v2(opened); db = nil; throw error }
    }

    deinit { if let db { sqlite3_close_v2(db) } }

    @discardableResult
    public func upsert(_ document: VaultIndexedDocument) throws -> Bool {
        try sync {
            try retryBusy {
                try transaction { try upsertLocked(document) }
            }
        }
    }

    /// Applies a set of index revisions atomically. This is the production
    /// ingestion path for large imports and also gives performance tests the
    /// same durable SQLite work without paying one BEGIN/COMMIT per record.
    @discardableResult
    public func upsertBatch(_ documents: [VaultIndexedDocument]) throws -> Int {
        try sync { try retryBusy {
            let prepared = try PreparedBulkStatements(database: db)
            return try transaction {
            var inserted = 0
            for document in documents {
                if try upsertLocked(document, prepared: prepared) { inserted += 1 }
            }
            return inserted
            }
        } }
    }

    /// Indexes a lazy sequence without materializing its entire input. Each
    /// batch is one SQLite transaction, so a failure leaves a durable prefix
    /// and never leaves documents/FTS/embeddings partially committed. Callers
    /// may replay the source after a failure: revision stamps make that resume
    /// idempotent and the callback is emitted only after COMMIT succeeds.
    @discardableResult
    public func upsertStreaming<S: Sequence>(
        _ documents: S,
        batchSize: Int = 256,
        progress: ((VaultIndexBatchProgress) -> Void)? = nil
    ) throws -> VaultIndexBulkResult where S.Element == VaultIndexedDocument {
        try validateBatchSize(batchSize)
        var batch: [VaultIndexedDocument] = []
        batch.reserveCapacity(batchSize)
        var totals = BulkTotals()
        for document in documents {
            batch.append(document)
            if batch.count == batchSize {
                try consumeBulkBatch(&batch, batchNumber: totals.batchesCommitted + 1,
                                     totals: &totals, progress: progress)
            }
        }
        if !batch.isEmpty {
            try consumeBulkBatch(&batch, batchNumber: totals.batchesCommitted + 1,
                                 totals: &totals, progress: progress)
        }
        return totals.result
    }

    /// AsyncSequence counterpart for importers that read file metadata or
    /// extraction output asynchronously. Only `batchSize` documents are held
    /// between commits; no task group or result array is retained.
    @discardableResult
    public func upsertStreaming<S: AsyncSequence>(
        _ documents: S,
        batchSize: Int = 256,
        progress: ((VaultIndexBatchProgress) -> Void)? = nil
    ) async throws -> VaultIndexBulkResult where S.Element == VaultIndexedDocument {
        try validateBatchSize(batchSize)
        var batch: [VaultIndexedDocument] = []
        batch.reserveCapacity(batchSize)
        var totals = BulkTotals()
        for try await document in documents {
            batch.append(document)
            if batch.count == batchSize {
                try consumeBulkBatch(&batch, batchNumber: totals.batchesCommitted + 1,
                                     totals: &totals, progress: progress)
            }
        }
        if !batch.isEmpty {
            try consumeBulkBatch(&batch, batchNumber: totals.batchesCommitted + 1,
                                 totals: &totals, progress: progress)
        }
        return totals.result
    }

    /// Chunk-producer form for importers whose source naturally produces
    /// bounded pages. The producer must return at most `batchSize` elements;
    /// violating that contract fails before any part of the oversized page is
    /// committed. Returning nil marks end of input.
    @discardableResult
    public func upsertStreaming(
        batchSize: Int = 256,
        nextBatch: () throws -> [VaultIndexedDocument]?,
        progress: ((VaultIndexBatchProgress) -> Void)? = nil
    ) throws -> VaultIndexBulkResult {
        try validateBatchSize(batchSize)
        var totals = BulkTotals()
        while let page = try nextBatch() {
            guard !page.isEmpty else { continue }
            guard page.count <= batchSize else { throw VaultSearchError.invalidBatchSize(page.count) }
            var boundedPage = page
            try consumeBulkBatch(&boundedPage, batchNumber: totals.batchesCommitted + 1,
                                 totals: &totals, progress: progress)
        }
        return totals.result
    }

    private func validateBatchSize(_ batchSize: Int) throws {
        guard (1...4_096).contains(batchSize) else { throw VaultSearchError.invalidBatchSize(batchSize) }
    }

    private func consumeBulkBatch(
        _ batch: inout [VaultIndexedDocument],
        batchNumber: Int,
        totals: inout BulkTotals,
        progress: ((VaultIndexBatchProgress) -> Void)?
    ) throws {
        let sourceCount = batch.count
        let applied = try upsertBatch(batch)
        // Release every document (and its potentially large extracted text or
        // embedding) before asking the source for the next batch.
        batch.removeAll(keepingCapacity: true)
        totals.batchesCommitted += 1
        totals.documentsProcessed += sourceCount
        totals.documentsApplied += applied
        totals.documentsSkipped += sourceCount - applied
        progress?(VaultIndexBatchProgress(batchNumber: batchNumber,
            documentsProcessed: totals.documentsProcessed,
            documentsApplied: totals.documentsApplied,
            documentsSkipped: totals.documentsSkipped))
    }

    private struct BulkTotals {
        var batchesCommitted = 0
        var documentsProcessed = 0
        var documentsApplied = 0
        var documentsSkipped = 0
        var result: VaultIndexBulkResult {
            VaultIndexBulkResult(batchesCommitted: batchesCommitted,
                documentsProcessed: documentsProcessed,
                documentsApplied: documentsApplied,
                documentsSkipped: documentsSkipped)
        }
    }

    @discardableResult
    private func upsertLocked(_ document: VaultIndexedDocument,
                              prepared: PreparedBulkStatements? = nil) throws -> Bool {
        if prepared == nil, let old = try stampLocked(document.id), old >= document.stamp { return false }
        if let embedding = document.embedding {
            _ = try embedding.validated()
            if let prepared {
                try prepared.ensureModelSpace(embedding.modelVersion, dimension: embedding.dimension)
            } else {
                try ensureModelSpace(embedding.modelVersion, dimension: embedding.dimension)
            }
        }
        let values: [SQLiteValue] = [
            .text(document.id.rawValue.uuidString), .text(document.revision.uuidString),
            .int(document.logicalTime), .text(document.deviceID), .text(document.filename),
            .text(document.bodyText), .text(document.ocrText), .text(document.transcriptText),
            .double(document.createdAt.timeIntervalSinceReferenceDate),
            .double(document.updatedAt.timeIntervalSinceReferenceDate),
            .double(document.accessedAt.timeIntervalSinceReferenceDate),
            .text(document.source.rawValue), .int(document.isTombstone ? 1 : 0),
        ]
        if let prepared {
            // The revision predicate is evaluated by SQLite, avoiding a
            // prepare/step/finalize lookup for every imported document.
            guard try prepared.upsert.executeReturningChanges(values) > 0 else { return false }
        } else {
            try run("""
            INSERT INTO documents(id,revision,logical_time,device_id,filename,body,ocr,transcript,created_at,updated_at,accessed_at,source,tombstone)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,logical_time=excluded.logical_time,
            device_id=excluded.device_id,filename=excluded.filename,body=excluded.body,ocr=excluded.ocr,
            transcript=excluded.transcript,created_at=excluded.created_at,updated_at=excluded.updated_at,
            accessed_at=excluded.accessed_at,source=excluded.source,tombstone=excluded.tombstone
            """, values)
        }
        try removeFTSProjectionLocked(document.id, prepared: prepared)
        if !document.isTombstone {
            let ftsValues: [SQLiteValue] = [
                .text(document.id.rawValue.uuidString), .text(document.filename), .text(document.bodyText),
                .text(document.ocrText), .text(document.transcriptText),
            ]
            if let prepared { try prepared.insertFTS.execute(ftsValues) }
            else { try run("INSERT INTO vault_fts(id,filename,body,ocr,transcript) VALUES(?,?,?,?,?)", ftsValues) }
            // Record the FTS5 rowid this document now owns so a later
            // upsert/delete can target `vault_fts` by rowid instead of
            // scanning it by the UNINDEXED `id` column.
            guard let db else { throw VaultSearchError.sqlite("database closed") }
            let rowIDValues: [SQLiteValue] = [.int(sqlite3_last_insert_rowid(db)), .text(document.id.rawValue.uuidString)]
            if let prepared { try prepared.setFTSRowID.execute(rowIDValues) }
            else { try run("UPDATE documents SET fts_rowid=? WHERE id=?", rowIDValues) }
            if let embedding = document.embedding {
                // Scope the delete to the incoming model version: re-indexing
                // this object under model B must not destroy a stored model-A
                // vector, since the schema is deliberately multi-model.
                try removeEmbeddingsLocked(document.id, modelVersion: embedding.modelVersion, prepared: prepared)
                let embeddingValues: [SQLiteValue] = [
                    .text(document.id.rawValue.uuidString), .text(embedding.modelVersion),
                    .int(Int64(embedding.dimension)), .blob(Self.encode(embedding.values)),
                ]
                if let prepared { try prepared.insertEmbedding.execute(embeddingValues) }
                else { try run("INSERT INTO embeddings(object_id,model_version,dimension,\"values\") VALUES(?,?,?,?)", embeddingValues) }
            }
        } else {
            // The object itself is gone: clear its embeddings under every
            // model, not just one, along with every other projection.
            try removeEmbeddingsLocked(document.id, modelVersion: nil, prepared: prepared)
            let id: [SQLiteValue] = [.text(document.id.rawValue.uuidString)]
            if let prepared {
                try prepared.deleteGroupMembers.execute(id)
                try prepared.deleteQueryGroupMembers.execute(id)
                try prepared.deleteAliases.execute(id)
            } else {
                try run("DELETE FROM group_members WHERE object_id=?", id)
                try run("DELETE FROM query_group_members WHERE object_id=?", id)
                try run("DELETE FROM aliases WHERE original_id=?", id)
            }
        }
        return true
    }

    /// A delete is itself a versioned index record. It is durable even if this
    /// device has never seen the object and therefore prevents later stale resurrection.
    @discardableResult
    public func delete(_ id: VaultObjectID, stamp: VaultIndexRevision,
                       deletedAt: Date = Date(), source: VaultDocumentSource = .device) throws -> Bool {
        let old = try document(id)
        return try upsert(VaultIndexedDocument(id: id, revision: stamp.revision,
            logicalTime: stamp.logicalTime, deviceID: stamp.deviceID,
            filename: old?.filename ?? "", createdAt: old?.createdAt ?? deletedAt,
            updatedAt: deletedAt, accessedAt: deletedAt, source: old?.source ?? source,
            isTombstone: true))
    }

    @discardableResult
    public func delete(_ id: VaultObjectID, revision: UUID = UUID()) throws -> Bool {
        try delete(id, stamp: VaultIndexRevision(
            logicalTime: Int64(Date().timeIntervalSince1970 * 1_000), deviceID: "local", revision: revision))
    }

    public func document(_ id: VaultObjectID) throws -> VaultIndexedDocument? {
        try sync { try documentLocked(id) }
    }

    public func allDocuments(includeTombstones: Bool = false) throws -> [VaultIndexedDocument] {
        try sync { try documentsLocked(includeTombstones: includeTombstones) }
    }

    /// Returns the most recently accessed live objects using a bounded SQL
    /// query. This deliberately does not call `allDocuments()` and sort in
    /// Swift: a large Vault should retain at most `limit` decoded rows for its
    /// home-screen recents rail.
    public func recent(limit: Int = 20) throws -> [VaultSearchHit] {
        guard (1...1_000).contains(limit) else { throw VaultSearchError.invalidLimit(limit) }
        return try sync { try recentLocked(limit: limit) }
    }

    /// Returns a count without decoding or retaining document rows. Import and
    /// performance callers should use this instead of `allDocuments()` when
    /// they only need a cardinality check.
    public func documentCount(includeTombstones: Bool = false) throws -> Int {
        try sync {
            Int(try scalar(includeTombstones
                ? "SELECT COUNT(*) FROM documents"
                : "SELECT COUNT(*) FROM documents WHERE tombstone=0"))
        }
    }

    /// Truncates the WAL after a durable batch import. This is intentionally a
    /// small public maintenance seam so diagnostics can report the actual
    /// checkpointed database footprint without reading every row.
    public func checkpointWAL() throws {
        try sync {
            guard let db else { throw VaultSearchError.sqlite("database closed") }
            let status = walCheckpointing.checkpoint(database: db)
            guard status == SQLITE_OK else {
                throw VaultSearchError.sqlite("WAL checkpoint failed (status \(status)): \(String(cString: sqlite3_errmsg(db)))")
            }
            try protectDatabaseFiles()
        }
    }

    public func search(_ text: String, embedding: VaultEmbedding? = nil, limit: Int? = nil) throws -> [VaultSearchHit] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw VaultSearchError.invalidQuery }
        let limit = limit ?? configuration.maximumResults
        guard (1...1_000).contains(limit) else { throw VaultSearchError.invalidLimit(limit) }
        return try sync { try searchLocked(text, embedding: embedding, limit: limit) }
    }

    public func cosineSearch(_ embedding: VaultEmbedding, limit: Int = 50) throws -> [(VaultObjectID, Double)] {
        guard (1...1_000).contains(limit) else { throw VaultSearchError.invalidLimit(limit) }
        return try sync { try vectorCandidates(embedding, limit: limit).map { ($0.displayedID, $0.score) } }
    }

    public func embedding(for objectID: VaultObjectID, modelVersion: String) throws -> VaultEmbedding? {
        try sync { try vectorLocked(objectID, modelVersion: modelVersion) }
    }

    public func rebuild(modelVersion: String? = nil) throws {
        try sync { try retryBusy { try transaction {
            if let modelVersion {
                try run("DELETE FROM embeddings WHERE model_version<>?", [.text(modelVersion)])
                try run("DELETE FROM aliases WHERE model_version<>?", [.text(modelVersion)])
            }
            try run("DELETE FROM vault_fts")
            try run("INSERT INTO vault_fts(id,filename,body,ocr,transcript) SELECT id,filename,body,ocr,transcript FROM documents WHERE tombstone=0")
            // The bulk rebuild assigns fresh FTS5 rowids; refresh the stored
            // mapping so the next upsert/delete can still target them directly.
            try run("UPDATE documents SET fts_rowid=(SELECT vault_fts.rowid FROM vault_fts WHERE vault_fts.id=documents.id)")
        } } }
    }

    public func groups() throws -> [VaultGroup] { try sync { try groupsLocked() } }

    /// Bounded query-group listing for presentation. Snapshot groups return
    /// their persisted canonical membership; live groups resolve through the
    /// same bounded search path used by `queryGroup`.
    public func queryGroups(limit: Int = 100) throws -> [VaultQueryGroup] {
        guard (1...1_000).contains(limit) else { throw VaultSearchError.invalidLimit(limit) }
        return try sync {
            var result: [VaultQueryGroup] = []
            try queryRows("SELECT id,query,live,created_at FROM query_groups ORDER BY created_at DESC,id LIMIT ?",
                          [.int(Int64(limit))]) { row in
                guard let id = UUID(uuidString: row.text(0) ?? "") else { return }
                let query = row.text(1) ?? ""
                let live = row.int(2) != 0
                let members = live
                    ? try self.searchLocked(query, embedding: nil,
                                            limit: self.configuration.maximumResults)
                        .map(\.canonicalObjectID)
                    : try self.queryMembers(groupID: id)
                result.append(VaultQueryGroup(id: id, query: query,
                    memberIDs: members, live: live,
                    createdAt: Date(timeIntervalSinceReferenceDate: row.double(3))))
            }
            return result
        }
    }

    /// The model version is part of manual membership/alias creation. UI
    /// callers must obtain it explicitly instead of guessing or silently
    /// dropping an add-to-group request.
    public func modelVersions(limit: Int = 20) throws -> [String] {
        guard (1...100).contains(limit) else { throw VaultSearchError.invalidLimit(limit) }
        return try sync {
            var result: [String] = []
            try queryRows("SELECT model_version FROM model_spaces ORDER BY model_version LIMIT ?",
                          [.int(Int64(limit))]) { row in
                if let version = row.text(0), !version.isEmpty { result.append(version) }
            }
            return result
        }
    }

    public func createGroup(label: String, members: [VaultObjectID] = [], frozen: Bool = true) throws -> VaultGroup {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw VaultSearchError.invalidQuery }
        return try sync { try retryBusy {
            try transaction {
                let canonical = try validatedCanonicalMembers(members)
                let now = Date(), id = UUID()
                try run("INSERT INTO groups(id,label,frozen,automatic,created_at,updated_at,member_count) VALUES(?,?,?,?,?,?,?)", [
                    .text(id.uuidString), .text(label), .int(frozen ? 1 : 0), .int(0),
                    .double(now.timeIntervalSinceReferenceDate), .double(now.timeIntervalSinceReferenceDate),
                    .int(Int64(canonical.count)),
                ])
                for member in canonical { try addGroupMember(groupID: id, objectID: member) }
                return VaultGroup(id: id, label: label, memberIDs: canonical, frozen: frozen,
                                  automatic: false, createdAt: now, updatedAt: now)
            }
        } }
    }

    public func renameGroup(_ id: UUID, label: String, frozen: Bool? = nil) throws {
        try sync { try retryBusy { try transaction { try run("UPDATE groups SET label=?,frozen=COALESCE(?,frozen),updated_at=? WHERE id=?", [
            .text(label), frozen.map { .int($0 ? 1 : 0) } ?? .null,
            .double(Date().timeIntervalSinceReferenceDate), .text(id.uuidString),
        ]) } } }
    }

    public func setGroupFrozen(_ id: UUID, frozen: Bool) throws {
        try sync { try retryBusy { try transaction { try run("UPDATE groups SET frozen=?,updated_at=? WHERE id=?", [
            .int(frozen ? 1 : 0), .double(Date().timeIntervalSinceReferenceDate), .text(id.uuidString),
        ]) } } }
    }

    /// One pass over objects and a bounded number of stored centroids. This is
    /// exact against those centroids, not an HNSW claim.
    @discardableResult
    public func evolveAutomaticGroups(modelVersion: String, threshold: Double = 0.78) throws -> [VaultGroup] {
        try sync { try retryBusy { try transaction {
            var centroids = try automaticCentroids(modelVersion: modelVersion)
            let candidates = try liveVectors(modelVersion: modelVersion)
            for candidate in candidates where !(try isAutomaticMember(candidate.id)) {
                let ranked = centroids.enumerated().filter { !$0.element.frozen }.map {
                    ($0.offset, Self.cosine(candidate.values, $0.element.values))
                }.sorted { $0.1 == $1.1 ? centroids[$0.0].id.uuidString < centroids[$1.0].id.uuidString : $0.1 > $1.1 }
                if let (index, score) = ranked.first,
                   score >= threshold || centroids.count >= configuration.maximumAutomaticGroups {
                    try addGroupMember(groupID: centroids[index].id, objectID: candidate.id)
                    centroids[index].add(candidate.values)
                    try persistCentroid(centroids[index])
                } else if centroids.count < configuration.maximumAutomaticGroups {
                    // Every centroid is frozen (`ranked` is empty) or none
                    // qualifies, and the group cap still has room: mint a new
                    // automatic group. When the cap is already full, fall
                    // through and leave this candidate unclustered rather
                    // than growing past `maximumAutomaticGroups`.
                    let now = Date(), id = UUID()
                    let doc = try documentLocked(candidate.id).map { [$0] } ?? []
                    let centroid = AutomaticCentroid(id: id, frozen: false, values: candidate.values,
                                                     count: 1, modelVersion: modelVersion)
                    try run("INSERT INTO groups(id,label,frozen,automatic,created_at,updated_at,model_version,dimension,centroid,member_count) VALUES(?,?,?,?,?,?,?,?,?,?)", [
                        .text(id.uuidString), .text(namer.name(for: doc)), .int(0), .int(1),
                        .double(now.timeIntervalSinceReferenceDate), .double(now.timeIntervalSinceReferenceDate),
                        .text(modelVersion), .int(Int64(candidate.values.count)),
                        .blob(Self.encode(candidate.values)), .int(1),
                    ])
                    try addGroupMember(groupID: id, objectID: candidate.id)
                    centroids.append(centroid)
                }
            }
            return try groupsLocked()
        } } }
    }

    public func createQueryGroup(query: String, members: [VaultObjectID], live: Bool = false) throws -> VaultQueryGroup {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw VaultSearchError.invalidQuery }
        return try sync { try retryBusy { try transaction {
            let canonical = try validatedCanonicalMembers(members)
            let id = UUID(), now = Date()
            try run("INSERT INTO query_groups(id,query,live,created_at) VALUES(?,?,?,?)", [
                .text(id.uuidString), .text(query), .int(live ? 1 : 0), .double(now.timeIntervalSinceReferenceDate),
            ])
            for member in canonical {
                try run("INSERT INTO query_group_members(group_id,object_id) VALUES(?,?)", [
                    .text(id.uuidString), .text(member.rawValue.uuidString),
                ])
            }
            return VaultQueryGroup(id: id, query: query, memberIDs: canonical, live: live, createdAt: now)
        } } }
    }

    public func queryGroup(_ id: UUID, embedding: VaultEmbedding? = nil) throws -> VaultQueryGroup? {
        try sync { try retryBusy { try transaction {
            var result: VaultQueryGroup?
            try queryRows("SELECT query,live,created_at FROM query_groups WHERE id=?", [.text(id.uuidString)]) { row in
                let queryText = row.text(0) ?? "", live = row.int(1) != 0
                let members: [VaultObjectID]
                if live {
                    members = try searchLocked(queryText, embedding: embedding,
                                               limit: configuration.maximumResults).map(\.canonicalObjectID)
                } else {
                    members = try queryMembers(groupID: id)
                }
                result = VaultQueryGroup(id: id, query: queryText, memberIDs: members,
                    live: live, createdAt: Date(timeIntervalSinceReferenceDate: row.double(2)))
            }
            return result
        } } }
    }

    @discardableResult
    public func addManualMembership(objectID: VaultObjectID, toGroup groupID: UUID,
                                    modelVersion: String) throws -> VaultSymbolicAlias {
        try sync { try retryBusy { try transaction {
            let canonical = try canonicalLocked(objectID)
            guard let document = try documentLocked(canonical) else { throw VaultSearchError.missingDocument }
            guard !document.isTombstone else { throw VaultSearchError.tombstonedDocument }
            guard try groupExists(groupID) else { throw VaultSearchError.missingDocument }
            guard let original = try vectorLocked(canonical, modelVersion: modelVersion) else {
                throw VaultSearchError.missingDocument
            }
            let joined = try addGroupMember(groupID: groupID, objectID: canonical)
            if let existing = try aliasLocked(originalID: canonical, groupID: groupID, modelVersion: modelVersion) {
                return existing
            }
            // A manual add can target an automatic group (the UI allows it);
            // keep member_count honest for evolve's incremental-average
            // weighting instead of leaving it stuck at its automatic value.
            if joined {
                try run("UPDATE groups SET member_count=member_count+1,updated_at=? WHERE id=?", [
                    .double(Date().timeIntervalSinceReferenceDate), .text(groupID.uuidString),
                ])
            }
            let memberVectors = try groupVectors(groupID: groupID, modelVersion: modelVersion)
            let label = Self.centroid(memberVectors)
            var values = label.values
            for index in values.indices { values[index] += (original.values[index] - values[index]) * 0.05 }
            // Keep a deterministic, non-zero displacement for a single-member group.
            if values == original.values, !values.isEmpty { values[0] = values[0].nextUp }
            let aliasID = UUID(), embedding = VaultEmbedding(values: values, modelVersion: modelVersion)
            try run("INSERT INTO aliases(id,original_id,group_id,model_version,dimension,\"values\") VALUES(?,?,?,?,?,?)", [
                .text(aliasID.uuidString), .text(canonical.rawValue.uuidString), .text(groupID.uuidString),
                .text(modelVersion), .int(Int64(values.count)), .blob(Self.encode(values)),
            ])
            return VaultSymbolicAlias(id: aliasID, originalObjectID: canonical,
                                      groupID: groupID, embedding: embedding)
        } } }
    }

    public func resolveCanonical(_ objectID: VaultObjectID) throws -> VaultObjectID {
        try sync { try canonicalLocked(objectID) }
    }

    public func aliases(for objectID: VaultObjectID) throws -> [VaultSymbolicAlias] {
        try sync {
            let canonical = try canonicalLocked(objectID)
            guard let doc = try documentLocked(canonical), !doc.isTombstone else { return [] }
            var result: [VaultSymbolicAlias] = []
            try queryRows("SELECT id,group_id,model_version,dimension,\"values\" FROM aliases WHERE original_id=? ORDER BY id", [.text(canonical.rawValue.uuidString)]) { row in
                guard let aliasID = UUID(uuidString: row.text(0) ?? ""),
                      let groupID = UUID(uuidString: row.text(1) ?? ""),
                      let values = Self.decodeFinite(row.blob(4), count: Int(row.int(3))) else { return }
                result.append(VaultSymbolicAlias(id: aliasID, originalObjectID: canonical,
                    groupID: groupID, embedding: VaultEmbedding(values: values, modelVersion: row.text(2) ?? "")))
            }
            return result
        }
    }

    public func encryptedExport(cryptor: VaultChunkedCryptor, root: VaultRootKey,
                                objectID: VaultObjectID, revision: UUID) throws -> VaultEncryptedArtifact {
        try sync {
            guard let db else { throw VaultSearchError.sqlite("database closed") }
            let status = walCheckpointing.checkpoint(database: db)
            guard status == SQLITE_OK else {
                let message = String(cString: sqlite3_errmsg(db))
                throw VaultSearchError.sqlite("WAL checkpoint failed (status \(status)): \(message)")
            }
            try protectDatabaseFiles()
            guard let plaintext = FileManager.default.contents(atPath: databaseURL.path) else {
                throw VaultSearchError.invalidArtifact
            }
            let frames = try cryptor.seal(plaintext, objectID: objectID, revision: revision,
                                          root: root, role: .index)
            return try VaultEncryptedArtifact(kind: .index, vaultID: cryptor.vaultID,
                revision: revision, rootVersion: root.version, encryptedFrames: frames)
        }
    }

    public static func restoreEncryptedExport(_ artifact: VaultEncryptedArtifact,
                                              cryptor: VaultChunkedCryptor,
                                              to databaseURL: URL,
                                              protectionApplier: VaultFileProtectionApplying = SystemVaultFileProtectionApplier(),
                                              rootKey: (UInt32) throws -> VaultRootKey) throws {
        guard artifact.kind == .index, artifact.vaultID == cryptor.vaultID else { throw VaultSearchError.invalidArtifact }
        let plaintext = try cryptor.open(artifact.encryptedFrames, objectID: artifact.objectID,
            revision: artifact.revision, role: .index, rootKey: rootKey)
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try protectionApplier.apply(to: directory)
        let staging = directory.appendingPathComponent(".vault-index-restore-\(UUID().uuidString)")
        do {
            try plaintext.write(to: staging, options: [.atomic])
            try protectionApplier.apply(to: staging)
            _ = try FileManager.default.replaceItemAt(databaseURL, withItemAt: staging)
        } catch CocoaError.fileNoSuchFile {
            do {
                try FileManager.default.moveItem(at: staging, to: databaseURL)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: staging); throw error
        }
        try protectionApplier.apply(to: databaseURL)
        // A restored snapshot must never be reopened alongside the PRIOR
        // database's WAL/SHM: SQLite would recover those stale frames onto
        // this snapshot and silently corrupt it. `removeItem` unlinks a
        // matching symlink itself rather than following it, so a sibling
        // swapped for a symlink cannot redirect this cleanup either.
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + suffix))
        }
    }

    public func integrityCheck() throws -> String {
        try sync { var value = ""; try queryRows("PRAGMA integrity_check") { value = $0.text(0) ?? "" }; return value }
    }
    public func foreignKeysEnabled() throws -> Bool { try sync { try scalar("PRAGMA foreign_keys") == 1 } }

    /// Every step below runs inside the shared `transaction {}` helper, so a
    /// crash mid-migration rolls back to the schema `user_version` still
    /// names rather than stranding half-created tables. `CREATE TABLE IF NOT
    /// EXISTS` is kept as belt-and-braces re-entry safety on top of that.
    private func migrate() throws {
        var version = try scalar("PRAGMA user_version")
        if version == 0 {
            try transaction {
                try execute("""
                    CREATE TABLE IF NOT EXISTS documents(id TEXT PRIMARY KEY,revision TEXT NOT NULL,logical_time INTEGER NOT NULL,device_id TEXT NOT NULL,filename TEXT NOT NULL,body TEXT NOT NULL,ocr TEXT NOT NULL,transcript TEXT NOT NULL,created_at REAL NOT NULL,updated_at REAL NOT NULL,accessed_at REAL NOT NULL,source TEXT NOT NULL,tombstone INTEGER NOT NULL CHECK(tombstone IN(0,1)));
                    CREATE VIRTUAL TABLE IF NOT EXISTS vault_fts USING fts5(id UNINDEXED,filename,body,ocr,transcript);
                    CREATE TABLE IF NOT EXISTS model_spaces(model_version TEXT PRIMARY KEY,dimension INTEGER NOT NULL CHECK(dimension>0));
                    CREATE TABLE IF NOT EXISTS embeddings(object_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,model_version TEXT NOT NULL REFERENCES model_spaces(model_version),dimension INTEGER NOT NULL CHECK(dimension>0),\"values\" BLOB NOT NULL,PRIMARY KEY(object_id,model_version));
                    CREATE TABLE IF NOT EXISTS groups(id TEXT PRIMARY KEY,label TEXT NOT NULL,frozen INTEGER NOT NULL CHECK(frozen IN(0,1)),automatic INTEGER NOT NULL CHECK(automatic IN(0,1)),created_at REAL NOT NULL,updated_at REAL NOT NULL,model_version TEXT,dimension INTEGER,centroid BLOB,member_count INTEGER NOT NULL DEFAULT 0 CHECK(member_count>=0));
                    CREATE TABLE IF NOT EXISTS group_members(group_id TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,object_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,PRIMARY KEY(group_id,object_id));
                    CREATE TABLE IF NOT EXISTS query_groups(id TEXT PRIMARY KEY,query TEXT NOT NULL,live INTEGER NOT NULL CHECK(live IN(0,1)),created_at REAL NOT NULL);
                    CREATE TABLE IF NOT EXISTS query_group_members(group_id TEXT NOT NULL REFERENCES query_groups(id) ON DELETE CASCADE,object_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,PRIMARY KEY(group_id,object_id));
                    CREATE TABLE IF NOT EXISTS aliases(id TEXT PRIMARY KEY,original_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,group_id TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,model_version TEXT NOT NULL REFERENCES model_spaces(model_version),dimension INTEGER NOT NULL CHECK(dimension>0),\"values\" BLOB NOT NULL,UNIQUE(original_id,group_id,model_version));
                    CREATE INDEX IF NOT EXISTS embeddings_model ON embeddings(model_version);
                    CREATE INDEX IF NOT EXISTS aliases_model ON aliases(model_version);
                    """)
                try execute("PRAGMA user_version=2")
            }
            version = 2
        }
        if version == 1 {
            try transaction {
                try execute("ALTER TABLE documents ADD COLUMN logical_time INTEGER NOT NULL DEFAULT 0")
                try execute("ALTER TABLE documents ADD COLUMN device_id TEXT NOT NULL DEFAULT ''")
                try execute("CREATE TABLE IF NOT EXISTS model_spaces(model_version TEXT PRIMARY KEY,dimension INTEGER NOT NULL CHECK(dimension>0))")
                try execute("INSERT INTO model_spaces SELECT model_version,MIN(dimension) FROM embeddings GROUP BY model_version")
                let inconsistent = try scalar("SELECT COUNT(*) FROM (SELECT model_version FROM embeddings GROUP BY model_version HAVING MIN(dimension)<>MAX(dimension))")
                guard inconsistent == 0 else { throw VaultSearchError.mixedModelSpace }
                try execute("ALTER TABLE groups ADD COLUMN model_version TEXT")
                try execute("ALTER TABLE groups ADD COLUMN dimension INTEGER")
                try execute("ALTER TABLE groups ADD COLUMN centroid BLOB")
                try execute("ALTER TABLE groups ADD COLUMN member_count INTEGER NOT NULL DEFAULT 0")
                try execute("CREATE UNIQUE INDEX IF NOT EXISTS aliases_unique_membership ON aliases(original_id,group_id,model_version)")
                try execute("CREATE INDEX IF NOT EXISTS embeddings_model ON embeddings(model_version)")
                try execute("CREATE INDEX IF NOT EXISTS aliases_model ON aliases(model_version)")
                try execute("PRAGMA user_version=2")
            }
            version = 2
        }
        if version == 2 {
            try transaction {
                // `vault_fts` declares `id UNINDEXED`, so a delete keyed on it
                // used to run a full FTS scan. `fts_rowid` records each
                // document's FTS5 rowid so upsert/delete can target it
                // directly; the backfill below recovers it for every
                // pre-existing row from the one FTS5 lookup that scan needed
                // anyway, so later deletes never pay for it again.
                try execute("ALTER TABLE documents ADD COLUMN fts_rowid INTEGER")
                try execute("UPDATE documents SET fts_rowid=(SELECT vault_fts.rowid FROM vault_fts WHERE vault_fts.id=documents.id)")
                try execute("CREATE INDEX IF NOT EXISTS documents_accessed_at ON documents(accessed_at)")
                try execute("CREATE INDEX IF NOT EXISTS group_members_object_id ON group_members(object_id)")
                try execute("PRAGMA user_version=3")
            }
            version = 3
        }
        guard version == 3 else { throw VaultSearchError.sqlite("unsupported schema \(version)") }
    }

    /// Ranking is decided from lightweight candidate metadata only — never
    /// the up-to-16MB body/OCR/transcript text — so a large lexical or vector
    /// candidate set never retains full document text for hits that lose the
    /// ranking. Full text is fetched once, in one batched query, for exactly
    /// the winning `limit` hits after they are chosen.
    private func searchLocked(_ text: String, embedding: VaultEmbedding?, limit: Int) throws -> [VaultSearchHit] {
        var seeds: [VaultObjectID: HitSeed] = [:]
        let candidateLimit = min(configuration.maximumLexicalCandidates, max(limit * 8, limit))
        let tokens = Self.tokens(text)
        if !tokens.isEmpty {
            let match = tokens.map { "\"\($0)\"" }.joined(separator: " OR ")
            try queryRows("""
                SELECT d.id,d.revision,d.logical_time,d.device_id,d.filename,d.body,d.ocr,d.transcript,
                       d.created_at,d.updated_at,d.accessed_at,d.source,bm25(vault_fts)
                FROM vault_fts JOIN documents d ON d.id=vault_fts.id
                WHERE vault_fts MATCH ? AND d.tombstone=0
                ORDER BY bm25(vault_fts) ASC,d.id ASC LIMIT ?
                """, [.text(match), .int(Int64(candidateLimit))]) { row in
                // Matching-field detection needs the row's own text, but only
                // transiently: the decoded document is discarded once its
                // matched fields are read off, not retained in the seed.
                let document = try self.decodeSearchDocument(row)
                let fields = Self.matchingFields(document, text: text, tokens: tokens)
                let lexical = Self.bm25Score(row.double(12))
                seeds[document.id] = HitSeed(id: document.id, filename: document.filename,
                    createdAt: document.createdAt, updatedAt: document.updatedAt, accessedAt: document.accessedAt,
                    source: document.source, displayedID: document.id, alias: false,
                    lexical: lexical, exact: 0, vector: 0, fields: fields, displayScore: lexical)
            }
        }
        try queryRows("""
            SELECT id,filename,created_at,updated_at,accessed_at,source
            FROM documents WHERE tombstone=0 AND filename LIKE ? ESCAPE '\\'
            ORDER BY accessed_at DESC,id ASC LIMIT ?
            """, [.text("%\(Self.escapeLike(text))%"), .int(Int64(candidateLimit))]) { row in
            let candidate = try self.decodeCandidateMetadata(row)
            var seed = seeds[candidate.id] ?? HitSeed(id: candidate.id, filename: candidate.filename,
                createdAt: candidate.createdAt, updatedAt: candidate.updatedAt, accessedAt: candidate.accessedAt,
                source: candidate.source, displayedID: candidate.id, alias: false,
                lexical: 0, exact: 0, vector: 0, fields: [.filename], displayScore: 4)
            seed.exact = 1
            if seed.displayScore < 4 {
                seed.displayedID = candidate.id
                seed.alias = false
                seed.displayScore = 4
            }
            if !seed.fields.contains(.filename) { seed.fields.append(.filename) }
            seeds[candidate.id] = seed
        }
        // A label is a symbolic lexical entry for every manually linked object.
        // The match is against the group label, not the document's own text,
        // so this query never needed body/OCR/transcript columns at all.
        try queryRows("""
            SELECT a.id,d.id,d.filename,d.created_at,d.updated_at,d.accessed_at,d.source
            FROM aliases a JOIN groups g ON g.id=a.group_id JOIN documents d ON d.id=a.original_id
            WHERE d.tombstone=0 AND g.label LIKE ? ESCAPE '\\' ORDER BY g.label,a.id LIMIT ?
            """, [.text("%\(Self.escapeLike(text))%"), .int(Int64(candidateLimit))]) { row in
            guard let aliasUUID = UUID(uuidString: row.text(0) ?? "") else { return }
            let candidate = try self.decodeCandidateMetadata(row, offset: 1)
            let aliasID = VaultObjectID(rawValue: aliasUUID)
            var seed = seeds[candidate.id] ?? HitSeed(id: candidate.id, filename: candidate.filename,
                createdAt: candidate.createdAt, updatedAt: candidate.updatedAt, accessedAt: candidate.accessedAt,
                source: candidate.source, displayedID: aliasID, alias: true,
                lexical: 0, exact: 0, vector: 0, fields: [])
            let aliasScore = 1.0
            if aliasScore > seed.displayScore ||
                (aliasScore == seed.displayScore && Self.displayID(aliasID, alias: true, beats: seed.displayedID, currentAlias: seed.alias)) {
                seed.displayedID = aliasID
                seed.alias = true
                seed.displayScore = aliasScore
            }
            seed.lexical = max(seed.lexical, aliasScore)
            if !seed.fields.contains(.aliasLabel) { seed.fields.append(.aliasLabel) }
            seeds[candidate.id] = seed
        }
        if let embedding {
            for candidate in try vectorCandidates(embedding, limit: candidateLimit) {
                guard let metadata = try candidateMetadataLocked(candidate.canonicalID) else { continue }
                var seed = seeds[candidate.canonicalID] ?? HitSeed(id: candidate.canonicalID, filename: metadata.filename,
                    createdAt: metadata.createdAt, updatedAt: metadata.updatedAt, accessedAt: metadata.accessedAt,
                    source: metadata.source, displayedID: candidate.displayedID, alias: candidate.alias,
                    lexical: 0, exact: 0, vector: 0, fields: [.vector], displayScore: candidate.score)
                let candidateDisplayWins = candidate.score > seed.displayScore ||
                    (candidate.score == seed.displayScore && Self.displayID(candidate.displayedID, alias: candidate.alias,
                        beats: seed.displayedID, currentAlias: seed.alias))
                if candidateDisplayWins {
                    seed.displayedID = candidate.displayedID
                    seed.alias = candidate.alias
                    seed.displayScore = candidate.score
                }
                seed.vector = max(seed.vector, candidate.score)
                if !seed.fields.contains(.vector) { seed.fields.append(.vector) }
                seeds[candidate.canonicalID] = seed
            }
        }
        let sorted = seeds.values.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.accessedAt != $1.accessedAt { return $0.accessedAt > $1.accessedAt }
            return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }
        let winners = Array(sorted.prefix(limit))
        var texts: [VaultObjectID: (body: String, ocr: String, transcript: String)] = [:]
        if !winners.isEmpty {
            let placeholders = Array(repeating: "?", count: winners.count).joined(separator: ",")
            try queryRows("SELECT id,body,ocr,transcript FROM documents WHERE id IN (\(placeholders))",
                          winners.map { .text($0.id.rawValue.uuidString) }) { row in
                guard let uuid = UUID(uuidString: row.text(0) ?? "") else { return }
                texts[VaultObjectID(rawValue: uuid)] = (row.text(1) ?? "", row.text(2) ?? "", row.text(3) ?? "")
            }
        }
        return winners.map { seed in
            let fetched = texts[seed.id]
            let bodyText = fetched?.body ?? "", ocrText = fetched?.ocr ?? "", transcriptText = fetched?.transcript ?? ""
            let source = Self.preferredSnippetField(seed.fields, bodyTextIsEmpty: bodyText.isEmpty)
            let snippetText = Self.snippet(filename: seed.filename, bodyText: bodyText, ocrText: ocrText,
                                           transcriptText: transcriptText, field: source, text: text)
            return VaultSearchHit(objectID: seed.displayedID, canonicalObjectID: seed.id,
                filename: seed.filename, snippet: snippetText,
                snippetSource: source, score: seed.score, createdAt: seed.createdAt,
                updatedAt: seed.updatedAt, accessedAt: seed.accessedAt,
                source: seed.source, matchedFields: seed.fields.map(\.rawValue),
                isSymbolicAlias: seed.alias)
        }
    }

    private func vectorCandidates(_ query: VaultEmbedding, limit: Int) throws -> [VectorCandidate] {
        _ = try query.validated()
        if let expected = try modelDimension(query.modelVersion), expected != query.dimension {
            throw VaultSearchError.dimensionMismatch(expected: expected, actual: query.dimension)
        }
        // Keep only the best-scoring candidates while SQLite streams rows,
        // deduped by canonical object. A `[VaultObjectID: Int]` index makes
        // dedupe O(1) instead of an O(n) scan per row, and the buffer is only
        // sorted and trimmed once it overflows to 2x the limit rather than on
        // every single insertion, so a 100k-embedding scan pays for a handful
        // of sorts instead of one per candidate.
        var result: [VectorCandidate] = []
        var resultIndex: [VaultObjectID: Int] = [:]
        func trim() {
            result.sort(by: Self.candidateOrder)
            if result.count > limit { result.removeLast(result.count - limit) }
            resultIndex.removeAll(keepingCapacity: true)
            for (position, candidate) in result.enumerated() { resultIndex[candidate.canonicalID] = position }
        }
        func consider(_ candidate: VectorCandidate) {
            if let position = resultIndex[candidate.canonicalID] {
                if Self.preferred(candidate, over: result[position]) { result[position] = candidate }
            } else {
                result.append(candidate)
                resultIndex[candidate.canonicalID] = result.count - 1
            }
            if result.count > limit * 2 { trim() }
        }
        try queryRows("""
            SELECT e.object_id,e.dimension,e.\"values\" FROM embeddings e
            JOIN documents d ON d.id=e.object_id
            WHERE e.model_version=? AND d.tombstone=0
            """, [.text(query.modelVersion)]) { row in
            guard Int(row.int(1)) == query.dimension,
                  let uuid = UUID(uuidString: row.text(0) ?? ""),
                  let score = row.withBlob(2, body: { Self.cosine(query.values, bytes: $0, count: query.dimension) }) else { return }
            let candidate = VectorCandidate(displayedID: VaultObjectID(rawValue: uuid),
                canonicalID: VaultObjectID(rawValue: uuid), alias: false,
                score: score)
            consider(candidate)
        }
        try queryRows("""
            SELECT a.id,a.original_id,a.dimension,a.\"values\" FROM aliases a
            JOIN documents d ON d.id=a.original_id
            WHERE a.model_version=? AND d.tombstone=0
            """, [.text(query.modelVersion)]) { row in
            guard Int(row.int(2)) == query.dimension,
                  let alias = UUID(uuidString: row.text(0) ?? ""),
                  let original = UUID(uuidString: row.text(1) ?? ""),
                  let score = row.withBlob(3, body: { Self.cosine(query.values, bytes: $0, count: query.dimension) }) else { return }
            let candidate = VectorCandidate(displayedID: VaultObjectID(rawValue: alias),
                canonicalID: VaultObjectID(rawValue: original), alias: true,
                score: score)
            consider(candidate)
        }
        return result.sorted(by: Self.candidateOrder).prefix(limit).map { $0 }
    }

    private func ensureModelSpace(_ version: String, dimension: Int) throws {
        guard !version.isEmpty, dimension > 0 else { throw VaultSearchError.mixedModelSpace }
        if let old = try modelDimension(version) {
            guard old == dimension else { throw VaultSearchError.dimensionMismatch(expected: old, actual: dimension) }
        } else {
            try run("INSERT INTO model_spaces(model_version,dimension) VALUES(?,?)", [.text(version), .int(Int64(dimension))])
        }
    }

    private func modelDimension(_ version: String) throws -> Int? {
        var value: Int?; try queryRows("SELECT dimension FROM model_spaces WHERE model_version=?", [.text(version)]) { value = Int($0.int(0)) }; return value
    }

    /// Removes an object's `vault_fts` row by rowid rather than by its
    /// UNINDEXED `id` column, so this stays a point lookup instead of a full
    /// FTS scan on every upsert/delete. `fts_rowid` is cleared even when
    /// nothing matched, so a rowid can never be reused across objects if
    /// SQLite recycles it for an unrelated later insert.
    private func removeFTSProjectionLocked(_ id: VaultObjectID,
                                           prepared: PreparedBulkStatements? = nil) throws {
        let values: [SQLiteValue] = [.text(id.rawValue.uuidString)]
        if let prepared {
            try prepared.deleteFTS.execute(values)
            try prepared.clearFTSRowID.execute(values)
        } else {
            try run("DELETE FROM vault_fts WHERE rowid IN (SELECT fts_rowid FROM documents WHERE id=?)", values)
            try run("UPDATE documents SET fts_rowid=NULL WHERE id=?", values)
        }
    }

    /// Deletes an object's embeddings. Passing a `modelVersion` scopes the
    /// delete to that model so re-indexing under a new model space cannot
    /// destroy a vector stored under another; passing nil clears every model,
    /// which only a tombstone (a real object deletion) should ask for.
    private func removeEmbeddingsLocked(_ id: VaultObjectID, modelVersion: String?,
                                        prepared: PreparedBulkStatements? = nil) throws {
        if let modelVersion {
            let values: [SQLiteValue] = [.text(id.rawValue.uuidString), .text(modelVersion)]
            if let prepared { try prepared.deleteEmbeddingsForModel.execute(values) }
            else { try run("DELETE FROM embeddings WHERE object_id=? AND model_version=?", values) }
        } else {
            let values: [SQLiteValue] = [.text(id.rawValue.uuidString)]
            if let prepared { try prepared.deleteEmbeddings.execute(values) }
            else { try run("DELETE FROM embeddings WHERE object_id=?", values) }
        }
    }

    private func stampLocked(_ id: VaultObjectID) throws -> VaultIndexRevision? {
        var result: VaultIndexRevision?
        try queryRows("SELECT logical_time,device_id,revision FROM documents WHERE id=?", [.text(id.rawValue.uuidString)]) { row in
            guard let revision = UUID(uuidString: row.text(2) ?? "") else { throw VaultSearchError.sqlite("revision") }
            result = VaultIndexRevision(logicalTime: row.int(0), deviceID: row.text(1) ?? "", revision: revision)
        }
        return result
    }

    private func documentLocked(_ id: VaultObjectID) throws -> VaultIndexedDocument? {
        var result: VaultIndexedDocument?
        try queryRows("SELECT id,revision,logical_time,device_id,filename,body,ocr,transcript,created_at,updated_at,accessed_at,source,tombstone FROM documents WHERE id=?", [.text(id.rawValue.uuidString)]) { result = try self.decodeDocument($0) }
        return result
    }

    private func documentsLocked(includeTombstones: Bool) throws -> [VaultIndexedDocument] {
        var result: [VaultIndexedDocument] = []
        try queryRows("SELECT id,revision,logical_time,device_id,filename,body,ocr,transcript,created_at,updated_at,accessed_at,source,tombstone FROM documents\(includeTombstones ? "" : " WHERE tombstone=0") ORDER BY id") { result.append(try self.decodeDocument($0)) }
        return result
    }

    private func recentLocked(limit: Int) throws -> [VaultSearchHit] {
        var result: [VaultSearchHit] = []
        try queryRows("""
            SELECT id,revision,logical_time,device_id,filename,body,ocr,transcript,
                   created_at,updated_at,accessed_at,source
            FROM documents
            WHERE tombstone=0
            ORDER BY accessed_at DESC,id ASC
            LIMIT ?
            """, [.int(Int64(limit))]) { row in
            let document = try self.decodeSearchDocument(row)
            let field: VaultSearchField
            let text: String
            if !document.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                field = .text; text = document.bodyText
            } else if !document.ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                field = .ocr; text = document.ocrText
            } else if !document.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                field = .transcript; text = document.transcriptText
            } else {
                field = .filename; text = document.filename
            }
            let compact = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let snippet = String(compact.prefix(220))
            result.append(VaultSearchHit(objectID: document.id,
                canonicalObjectID: document.id, filename: document.filename,
                snippet: snippet, snippetSource: field, score: 0,
                createdAt: document.createdAt, updatedAt: document.updatedAt,
                accessedAt: document.accessedAt, source: document.source,
                matchedFields: [], isSymbolicAlias: false))
        }
        return result
    }

    private func decodeDocument(_ row: SQLiteRow) throws -> VaultIndexedDocument { try decodeSearchDocument(row, includesTombstone: true) }
    private func decodeSearchDocument(_ row: SQLiteRow, offset: Int = 0, includesTombstone: Bool = false) throws -> VaultIndexedDocument {
        guard let id = UUID(uuidString: row.text(offset) ?? ""),
              let revision = UUID(uuidString: row.text(offset + 1) ?? ""),
              let source = VaultDocumentSource(rawValue: row.text(offset + 11) ?? "") else { throw VaultSearchError.sqlite("document") }
        return VaultIndexedDocument(id: VaultObjectID(rawValue: id), revision: revision,
            logicalTime: row.int(offset + 2), deviceID: row.text(offset + 3) ?? "",
            filename: row.text(offset + 4) ?? "", bodyText: row.text(offset + 5) ?? "",
            ocrText: row.text(offset + 6) ?? "", transcriptText: row.text(offset + 7) ?? "",
            createdAt: Date(timeIntervalSinceReferenceDate: row.double(offset + 8)),
            updatedAt: Date(timeIntervalSinceReferenceDate: row.double(offset + 9)),
            accessedAt: Date(timeIntervalSinceReferenceDate: row.double(offset + 10)), source: source,
            isTombstone: includesTombstone && row.int(offset + 12) != 0)
    }

    /// Lightweight candidate metadata for ranking: filename, dates and source,
    /// never the (up to 16MB each) body/OCR/transcript columns a candidate
    /// query does not need until it wins.
    private struct CandidateMetadata { let id: VaultObjectID; let filename: String; let createdAt: Date; let updatedAt: Date; let accessedAt: Date; let source: VaultDocumentSource }
    private func decodeCandidateMetadata(_ row: SQLiteRow, offset: Int = 0) throws -> CandidateMetadata {
        guard let id = UUID(uuidString: row.text(offset) ?? ""),
              let source = VaultDocumentSource(rawValue: row.text(offset + 5) ?? "") else { throw VaultSearchError.sqlite("document") }
        return CandidateMetadata(id: VaultObjectID(rawValue: id), filename: row.text(offset + 1) ?? "",
            createdAt: Date(timeIntervalSinceReferenceDate: row.double(offset + 2)),
            updatedAt: Date(timeIntervalSinceReferenceDate: row.double(offset + 3)),
            accessedAt: Date(timeIntervalSinceReferenceDate: row.double(offset + 4)), source: source)
    }
    private func candidateMetadataLocked(_ id: VaultObjectID) throws -> CandidateMetadata? {
        var result: CandidateMetadata?
        try queryRows("SELECT id,filename,created_at,updated_at,accessed_at,source FROM documents WHERE id=? AND tombstone=0",
                      [.text(id.rawValue.uuidString)]) { result = try self.decodeCandidateMetadata($0) }
        return result
    }

    private func groupsLocked() throws -> [VaultGroup] {
        var result: [VaultGroup] = []
        try queryRows("SELECT id,label,frozen,automatic,created_at,updated_at FROM groups ORDER BY label,id") { row in
            guard let id = UUID(uuidString: row.text(0) ?? "") else { return }
            var members: [VaultObjectID] = []
            try self.queryRows("SELECT gm.object_id FROM group_members gm JOIN documents d ON d.id=gm.object_id WHERE gm.group_id=? AND d.tombstone=0 ORDER BY gm.object_id", [.text(id.uuidString)]) { member in
                if let uuid = UUID(uuidString: member.text(0) ?? "") { members.append(VaultObjectID(rawValue: uuid)) }
            }
            result.append(VaultGroup(id: id, label: row.text(1) ?? "", memberIDs: members,
                frozen: row.int(2) != 0, automatic: row.int(3) != 0,
                createdAt: Date(timeIntervalSinceReferenceDate: row.double(4)),
                updatedAt: Date(timeIntervalSinceReferenceDate: row.double(5))))
        }
        return result
    }

    private func validatedCanonicalMembers(_ members: [VaultObjectID]) throws -> [VaultObjectID] {
        var seen: Set<VaultObjectID> = [], result: [VaultObjectID] = []
        for member in members {
            let canonical = try canonicalLocked(member)
            guard seen.insert(canonical).inserted else { throw VaultSearchError.invalidSnapshotMember }
            guard let document = try documentLocked(canonical), !document.isTombstone else { throw VaultSearchError.invalidSnapshotMember }
            result.append(canonical)
        }
        return result
    }

    private func queryMembers(groupID: UUID) throws -> [VaultObjectID] {
        var result: [VaultObjectID] = []
        try queryRows("SELECT q.object_id FROM query_group_members q JOIN documents d ON d.id=q.object_id WHERE q.group_id=? AND d.tombstone=0 ORDER BY q.object_id", [.text(groupID.uuidString)]) { if let uuid=UUID(uuidString:$0.text(0) ?? "") { result.append(VaultObjectID(rawValue:uuid)) } }
        return result
    }

    private func canonicalLocked(_ id: VaultObjectID) throws -> VaultObjectID {
        var result = id
        try queryRows("SELECT original_id FROM aliases a JOIN documents d ON d.id=a.original_id WHERE a.id=? AND d.tombstone=0", [.text(id.rawValue.uuidString)]) { if let uuid=UUID(uuidString:$0.text(0) ?? "") { result=VaultObjectID(rawValue:uuid) } }
        return result
    }

    private func vectorLocked(_ id: VaultObjectID, modelVersion: String) throws -> VaultEmbedding? {
        var result: VaultEmbedding?
        try queryRows("SELECT e.dimension,e.\"values\" FROM embeddings e JOIN documents d ON d.id=e.object_id WHERE e.object_id=? AND e.model_version=? AND d.tombstone=0", [.text(id.rawValue.uuidString),.text(modelVersion)]) { row in
            let count=Int(row.int(0)); if let values=Self.decodeFinite(row.blob(1),count:count) { result=VaultEmbedding(values:values,modelVersion:modelVersion) }
        }
        return result
    }

    private func groupExists(_ id: UUID) throws -> Bool { try scalar("SELECT COUNT(*) FROM groups WHERE id=?", [.text(id.uuidString)]) == 1 }
    @discardableResult
    private func addGroupMember(groupID: UUID, objectID: VaultObjectID) throws -> Bool {
        try run("INSERT OR IGNORE INTO group_members(group_id,object_id) VALUES(?,?)", [.text(groupID.uuidString),.text(objectID.rawValue.uuidString)])
        guard let db else { throw VaultSearchError.sqlite("database closed") }
        return sqlite3_changes(db) > 0
    }
    private func isAutomaticMember(_ id: VaultObjectID) throws -> Bool { try scalar("SELECT COUNT(*) FROM group_members gm JOIN groups g ON g.id=gm.group_id WHERE gm.object_id=? AND g.automatic=1", [.text(id.rawValue.uuidString)]) > 0 }

    private func aliasLocked(originalID: VaultObjectID, groupID: UUID, modelVersion: String) throws -> VaultSymbolicAlias? {
        var result: VaultSymbolicAlias?
        try queryRows("SELECT id,dimension,\"values\" FROM aliases WHERE original_id=? AND group_id=? AND model_version=?", [.text(originalID.rawValue.uuidString),.text(groupID.uuidString),.text(modelVersion)]) { row in
            guard let id=UUID(uuidString:row.text(0) ?? ""),let values=Self.decodeFinite(row.blob(2),count:Int(row.int(1)))else{return};result=VaultSymbolicAlias(id:id,originalObjectID:originalID,groupID:groupID,embedding:VaultEmbedding(values:values,modelVersion:modelVersion))
        }
        return result
    }

    private func groupVectors(groupID: UUID, modelVersion: String) throws -> [VaultEmbedding] {
        var result: [VaultEmbedding] = []
        try queryRows("SELECT e.dimension,e.\"values\" FROM group_members gm JOIN embeddings e ON e.object_id=gm.object_id JOIN documents d ON d.id=gm.object_id WHERE gm.group_id=? AND e.model_version=? AND d.tombstone=0", [.text(groupID.uuidString),.text(modelVersion)]) { row in let count=Int(row.int(0));if let values=Self.decodeFinite(row.blob(1),count:count){result.append(VaultEmbedding(values:values,modelVersion:modelVersion))} }
        return result
    }

    private func liveVectors(modelVersion: String) throws -> [(id: VaultObjectID, values: [Float])] {
        var result: [(VaultObjectID,[Float])] = []
        try queryRows("SELECT e.object_id,e.dimension,e.\"values\" FROM embeddings e JOIN documents d ON d.id=e.object_id WHERE e.model_version=? AND d.tombstone=0 ORDER BY e.object_id", [.text(modelVersion)]) { row in guard let uuid=UUID(uuidString:row.text(0) ?? ""),let values=Self.decodeFinite(row.blob(2),count:Int(row.int(1)))else{return};result.append((VaultObjectID(rawValue:uuid),values)) }
        return result
    }

    private func automaticCentroids(modelVersion: String) throws -> [AutomaticCentroid] {
        var result: [AutomaticCentroid] = []
        try queryRows("SELECT id,frozen,dimension,centroid,member_count FROM groups WHERE automatic=1 AND model_version=? ORDER BY id", [.text(modelVersion)]) { row in guard let id=UUID(uuidString:row.text(0) ?? ""),let values=Self.decodeFinite(row.blob(3),count:Int(row.int(2)))else{return};result.append(AutomaticCentroid(id:id,frozen:row.int(1) != 0,values:values,count:max(1,Int(row.int(4))),modelVersion:modelVersion)) }
        return result
    }

    private func persistCentroid(_ centroid: AutomaticCentroid) throws { try run("UPDATE groups SET centroid=?,dimension=?,member_count=?,updated_at=? WHERE id=?", [.blob(Self.encode(centroid.values)),.int(Int64(centroid.values.count)),.int(Int64(centroid.count)),.double(Date().timeIntervalSinceReferenceDate),.text(centroid.id.uuidString)]) }

    private static func matchingFields(_ document: VaultIndexedDocument, text: String, tokens: [String]) -> [VaultSearchField] {
        let fields: [(VaultSearchField,String)] = [(.filename,document.filename),(.text,document.bodyText),(.ocr,document.ocrText),(.transcript,document.transcriptText)]
        return fields.compactMap { field,value in let lower=value.lowercased();return lower.contains(text.lowercased()) || tokens.contains(where:lower.contains) ? field:nil }
    }
    private static func preferredSnippetField(_ fields: [VaultSearchField], bodyTextIsEmpty: Bool) -> VaultSearchField {
        for field in [VaultSearchField.filename,.text,.ocr,.transcript,.aliasLabel,.vector] where fields.contains(field) { return field }
        return bodyTextIsEmpty ? .filename : .text
    }
    private static func snippet(filename: String, bodyText: String, ocrText: String, transcriptText: String, field: VaultSearchField, text: String) -> String {
        let value: String
        switch field { case .filename:value=filename;case .text:value=bodyText;case .ocr:value=ocrText;case .transcript:value=transcriptText;case .aliasLabel,.vector:value=bodyText.isEmpty ? filename:bodyText }
        guard let range=value.range(of:text,options:.caseInsensitive)else{return String(value.prefix(220))}
        let start=value.index(range.lowerBound,offsetBy:-90,limitedBy:value.startIndex) ?? value.startIndex
        let end=value.index(range.upperBound,offsetBy:110,limitedBy:value.endIndex) ?? value.endIndex
        return String(value[start..<end]).trimmingCharacters(in:.whitespacesAndNewlines)
    }
    private static func tokens(_ text:String)->[String]{text.lowercased().split(whereSeparator:{!$0.isLetter && !$0.isNumber}).map(String.init).filter{!$0.isEmpty}}
    private static func escapeLike(_ text:String)->String{text.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"%",with:"\\%").replacingOccurrences(of:"_",with:"\\_")}
    // SQLite FTS5's bm25() is ordered ascending: a more-negative value is a
    // stronger match. Convert it to a monotonic higher-is-better score without
    // reversing that order during hybrid ranking.
    private static func bm25Score(_ rank:Double)->Double{guard rank.isFinite else{return 0};return max(0,-rank)}
    private static func displayID(_ candidate: VaultObjectID, alias: Bool,
                                  beats current: VaultObjectID, currentAlias: Bool) -> Bool {
        if candidate.rawValue.uuidString != current.rawValue.uuidString {
            return candidate.rawValue.uuidString < current.rawValue.uuidString
        }
        return alias && !currentAlias
    }
    private static func preferred(_ candidate: VectorCandidate,
                                  over incumbent: VectorCandidate?) -> Bool {
        guard let incumbent else { return true }
        if candidate.score != incumbent.score { return candidate.score > incumbent.score }
        return displayID(candidate.displayedID, alias: candidate.alias,
                         beats: incumbent.displayedID, currentAlias: incumbent.alias)
    }
    private static func candidateOrder(_ lhs: VectorCandidate, _ rhs: VectorCandidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.displayedID.rawValue.uuidString != rhs.displayedID.rawValue.uuidString {
            return lhs.displayedID.rawValue.uuidString < rhs.displayedID.rawValue.uuidString
        }
        return lhs.canonicalID.rawValue.uuidString < rhs.canonicalID.rawValue.uuidString
    }
    private static func cosine(_ lhs:[Float], bytes: UnsafeRawBufferPointer, count: Int)->Double? {
        guard count == lhs.count, count > 0,
              bytes.count == count * MemoryLayout<Float>.size,
              let rhs = bytes.baseAddress?.assumingMemoryBound(to: Float.self) else { return nil }
        var dot = 0.0, lhsMagnitude = 0.0, rhsMagnitude = 0.0
        for index in 0..<count {
            let left = lhs[index], right = rhs[index]
            guard left.isFinite, right.isFinite else { return nil }
            let l = Double(left), r = Double(right)
            dot += l * r; lhsMagnitude += l * l; rhsMagnitude += r * r
        }
        guard dot.isFinite, lhsMagnitude.isFinite, rhsMagnitude.isFinite,
              lhsMagnitude > 0, rhsMagnitude > 0 else { return nil }
        let result = dot / (sqrt(lhsMagnitude) * sqrt(rhsMagnitude))
        return result.isFinite ? max(-1, min(1, result)) : nil
    }
    private static func cosine(_ lhs:[Float],_ rhs:[Float])->Double{guard lhs.count==rhs.count,!lhs.isEmpty,lhs.allSatisfy(\.isFinite),rhs.allSatisfy(\.isFinite)else{return 0};var dot=0.0,lm=0.0,rm=0.0;for index in lhs.indices{let l=Double(lhs[index]),r=Double(rhs[index]);dot += l*r;lm += l*l;rm += r*r};guard dot.isFinite,lm.isFinite,rm.isFinite,lm>0,rm>0 else{return 0};let result=dot/(sqrt(lm)*sqrt(rm));return result.isFinite ? max(-1,min(1,result)):0}
    private static func centroid(_ vectors:[VaultEmbedding])->VaultEmbedding{guard let first=vectors.first else{return VaultEmbedding(values:[],modelVersion:"")};var sums=Array(repeating:0.0,count:first.dimension);for vector in vectors where vector.dimension==first.dimension{for index in sums.indices{sums[index]+=Double(vector.values[index])}};return VaultEmbedding(values:sums.map{Float($0/Double(vectors.count))},modelVersion:first.modelVersion)}
    private static func encode(_ values:[Float])->Data{values.withUnsafeBufferPointer{Data(buffer:$0)}}
    private static func decodeFinite(_ data:Data?,count:Int)->[Float]?{guard count>0,let data,data.count==count*MemoryLayout<Float>.size else{return nil};let values=data.withUnsafeBytes{Array($0.bindMemory(to:Float.self))};return values.allSatisfy(\.isFinite) ? values:nil}

    // Re-applying file protection on every `sync` call — including plain
    // reads — meant a protection failure could fail an otherwise successful
    // query. It now runs only where it matters: at init (below), after a WAL
    // checkpoint/restore, and after a write transaction commits.
    private func protectDatabaseFiles() throws { for suffix in ["","-wal","-shm"] { let url=URL(fileURLWithPath:databaseURL.path+suffix);if FileManager.default.fileExists(atPath:url.path){try protection.apply(to:url)} } }
    private func sync<T>(_ body:()throws->T)throws->T{try queue.sync(execute:body)}
    private func retryBusy<T>(attempts:Int=8,_ body:()throws->T)throws->T{var attempt=0;while true{do{return try body()}catch let error as VaultSearchError{if case .sqlite(let message)=error,(message.contains("locked")||message.contains("busy")),attempt<attempts{Thread.sleep(forTimeInterval:0.01*Double(attempt+1));attempt += 1;continue};throw error}}}
    private func transaction<T>(_ body:()throws->T)throws->T{try execute("BEGIN IMMEDIATE");do{let value=try body();try execute("COMMIT");try protectDatabaseFiles();return value}catch{try?execute("ROLLBACK");throw error}}
    private func execute(_ sql:String)throws{var message:UnsafeMutablePointer<CChar>?;let status=sqlite3_exec(db,sql,nil,nil,&message);guard status==SQLITE_OK else{let text=message.map{String(cString:$0)} ?? String(cString:sqlite3_errmsg(db));sqlite3_free(message);throw VaultSearchError.sqlite(text)};sqlite3_free(message)}
    private func scalar(_ sql:String,_ values:[SQLiteValue]=[])throws->Int64{var result:Int64?;try queryRows(sql,values){if result==nil{result=$0.int(0)}};guard let result else{throw VaultSearchError.sqlite("scalar")};return result}
    private func run(_ sql:String,_ values:[SQLiteValue]=[])throws{try statement(sql,values){guard sqlite3_step($0)==SQLITE_DONE else{throw VaultSearchError.sqlite(String(cString:sqlite3_errmsg(db)))}}}
    private func queryRows(_ sql:String,_ values:[SQLiteValue]=[],body:(SQLiteRow)throws->Void)throws{try statement(sql,values){statement in while true{let status=sqlite3_step(statement);if status==SQLITE_DONE{return};guard status==SQLITE_ROW else{throw VaultSearchError.sqlite(String(cString:sqlite3_errmsg(db)))};try body(SQLiteRow(statement))}}}
    private func statement<T>(_ sql:String,_ values:[SQLiteValue],body:(OpaquePointer)throws->T)throws->T{var statement:OpaquePointer?;guard sqlite3_prepare_v2(db,sql,-1,&statement,nil)==SQLITE_OK,let statement else{throw VaultSearchError.sqlite(String(cString:sqlite3_errmsg(db)))};defer{sqlite3_finalize(statement)};for(index,value)in values.enumerated(){try value.bind(statement,Int32(index+1))};return try body(statement)}

    /// Statements shared for the lifetime of one bounded transaction. The
    /// normal single-document path intentionally remains simple; bulk imports
    /// avoid preparing/finalizing five statements for every document.
    private final class PreparedBulkStatements {
        let upsert: PreparedStatement
        let modelDimension: PreparedStatement
        let insertModelSpace: PreparedStatement
        let deleteFTS: PreparedStatement
        let clearFTSRowID: PreparedStatement
        let setFTSRowID: PreparedStatement
        let deleteEmbeddings: PreparedStatement
        let deleteEmbeddingsForModel: PreparedStatement
        let insertFTS: PreparedStatement
        let insertEmbedding: PreparedStatement
        let deleteGroupMembers: PreparedStatement
        let deleteQueryGroupMembers: PreparedStatement
        let deleteAliases: PreparedStatement
        private var modelDimensions: [String: Int] = [:]

        init(database: OpaquePointer?) throws {
            guard let database else { throw VaultSearchError.sqlite("database closed") }
            upsert = try PreparedStatement(database: database, sql: """
                INSERT INTO documents(id,revision,logical_time,device_id,filename,body,ocr,transcript,created_at,updated_at,accessed_at,source,tombstone)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,logical_time=excluded.logical_time,
                device_id=excluded.device_id,filename=excluded.filename,body=excluded.body,ocr=excluded.ocr,
                transcript=excluded.transcript,created_at=excluded.created_at,updated_at=excluded.updated_at,
                accessed_at=excluded.accessed_at,source=excluded.source,tombstone=excluded.tombstone
                WHERE excluded.logical_time > documents.logical_time
                   OR (excluded.logical_time = documents.logical_time AND
                       (excluded.device_id > documents.device_id OR
                        (excluded.device_id = documents.device_id AND excluded.revision > documents.revision)))
                """)
            modelDimension = try PreparedStatement(database: database, sql: "SELECT dimension FROM model_spaces WHERE model_version=?")
            insertModelSpace = try PreparedStatement(database: database, sql: "INSERT INTO model_spaces(model_version,dimension) VALUES(?,?)")
            deleteFTS = try PreparedStatement(database: database, sql: "DELETE FROM vault_fts WHERE rowid IN (SELECT fts_rowid FROM documents WHERE id=?)")
            clearFTSRowID = try PreparedStatement(database: database, sql: "UPDATE documents SET fts_rowid=NULL WHERE id=?")
            setFTSRowID = try PreparedStatement(database: database, sql: "UPDATE documents SET fts_rowid=? WHERE id=?")
            deleteEmbeddings = try PreparedStatement(database: database, sql: "DELETE FROM embeddings WHERE object_id=?")
            deleteEmbeddingsForModel = try PreparedStatement(database: database, sql: "DELETE FROM embeddings WHERE object_id=? AND model_version=?")
            insertFTS = try PreparedStatement(database: database, sql: "INSERT INTO vault_fts(id,filename,body,ocr,transcript) VALUES(?,?,?,?,?)")
            insertEmbedding = try PreparedStatement(database: database, sql: "INSERT INTO embeddings(object_id,model_version,dimension,\"values\") VALUES(?,?,?,?)")
            deleteGroupMembers = try PreparedStatement(database: database, sql: "DELETE FROM group_members WHERE object_id=?")
            deleteQueryGroupMembers = try PreparedStatement(database: database, sql: "DELETE FROM query_group_members WHERE object_id=?")
            deleteAliases = try PreparedStatement(database: database, sql: "DELETE FROM aliases WHERE original_id=?")
        }

        func ensureModelSpace(_ version: String, dimension: Int) throws {
            guard !version.isEmpty, dimension > 0 else { throw VaultSearchError.mixedModelSpace }
            let existing: Int?
            if let cached = modelDimensions[version] {
                existing = cached
            } else {
                existing = try modelDimension.fetchInt([.text(version)])
                if let existing { modelDimensions[version] = existing }
            }
            if let existing, existing != dimension {
                throw VaultSearchError.dimensionMismatch(expected: existing, actual: dimension)
            }
            if existing == nil {
                try insertModelSpace.execute([.text(version), .int(Int64(dimension))])
                modelDimensions[version] = dimension
            }
        }
    }

    private final class PreparedStatement {
        private let database: OpaquePointer
        private let statement: OpaquePointer

        init(database: OpaquePointer, sql: String) throws {
            self.database = database
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &prepared, nil) == SQLITE_OK,
                  let prepared else {
                throw VaultSearchError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            statement = prepared
        }

        deinit { sqlite3_finalize(statement) }

        func execute(_ values: [SQLiteValue]) throws {
            defer {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
            for (index, value) in values.enumerated() {
                try value.bind(statement, Int32(index + 1))
            }
            let status = sqlite3_step(statement)
            guard status == SQLITE_DONE else {
                throw VaultSearchError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
        }

        func executeReturningChanges(_ values: [SQLiteValue]) throws -> Int {
            defer {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
            for (index, value) in values.enumerated() {
                try value.bind(statement, Int32(index + 1))
            }
            let status = sqlite3_step(statement)
            guard status == SQLITE_DONE else {
                throw VaultSearchError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            return Int(sqlite3_changes(database))
        }

        func fetchInt(_ values: [SQLiteValue]) throws -> Int? {
            defer {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
            for (index, value) in values.enumerated() {
                try value.bind(statement, Int32(index + 1))
            }
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW else {
                throw VaultSearchError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    /// Ranking-only candidate state. Deliberately excludes body/OCR/transcript
    /// text — `searchLocked` fetches that once, only for the winning hits,
    /// after ranking is decided.
    private struct HitSeed{let id:VaultObjectID;let filename:String;let createdAt:Date;let updatedAt:Date;let accessedAt:Date;let source:VaultDocumentSource;var displayedID:VaultObjectID;var alias:Bool;var lexical:Double;var exact:Double;var vector:Double;var fields:[VaultSearchField];var displayScore:Double = 0;var score:Double{exact*4+lexical+vector*2}}
    private struct VectorCandidate{let displayedID:VaultObjectID;let canonicalID:VaultObjectID;let alias:Bool;let score:Double}
    private struct AutomaticCentroid{let id:UUID;let frozen:Bool;var values:[Float];var count:Int;let modelVersion:String;mutating func add(_ vector:[Float]){guard vector.count==values.count else{return};let next=Double(count+1);for index in values.indices{values[index]=Float((Double(values[index])*Double(count)+Double(vector[index]))/next)};count += 1}}
    private enum SQLiteValue{case null,text(String),int(Int64),double(Double),blob(Data);func bind(_ statement:OpaquePointer,_ index:Int32)throws{let status:Int32;switch self{case .null:status=sqlite3_bind_null(statement,index);case .text(let value):status=sqlite3_bind_text(statement,index,value,-1,vaultSearchSQLiteTransient);case .int(let value):status=sqlite3_bind_int64(statement,index,value);case .double(let value):status=sqlite3_bind_double(statement,index,value);case .blob(let value):status=value.withUnsafeBytes{sqlite3_bind_blob(statement,index,$0.baseAddress,Int32(value.count),vaultSearchSQLiteTransient)}};guard status==SQLITE_OK else{throw VaultSearchError.sqlite("bind")}}}
    private struct SQLiteRow{let statement:OpaquePointer;init(_ statement:OpaquePointer){self.statement=statement};func text(_ index:Int)->String?{guard let value=sqlite3_column_text(statement,Int32(index))else{return nil};return String(cString:value)};func int(_ index:Int)->Int64{sqlite3_column_int64(statement,Int32(index))};func double(_ index:Int)->Double{sqlite3_column_double(statement,Int32(index))};func blob(_ index:Int)->Data?{guard sqlite3_column_type(statement,Int32(index)) != SQLITE_NULL,let value=sqlite3_column_blob(statement,Int32(index))else{return nil};return Data(bytes:value,count:Int(sqlite3_column_bytes(statement,Int32(index))))};func withBlob<T>(_ index:Int,body:(UnsafeRawBufferPointer)->T?)->T?{guard sqlite3_column_type(statement,Int32(index)) != SQLITE_NULL,let value=sqlite3_column_blob(statement,Int32(index))else{return nil};return body(UnsafeRawBufferPointer(start:value,count:Int(sqlite3_column_bytes(statement,Int32(index)))))} }
}

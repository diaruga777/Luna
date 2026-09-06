import Foundation
import LunaWriterModels

public struct NoteQuery: Equatable, Sendable {
    public enum Scope: Equatable, Sendable {
        case document(DocumentID)
        case all
    }

    public var text: String
    public var scope: Scope
    /// True while the user is still typing the last word, so it matches as a
    /// prefix rather than as a whole word.
    public var prefixMatchesLastToken: Bool
    public var limit: Int

    public init(
        text: String, scope: Scope = .all, prefixMatchesLastToken: Bool = false, limit: Int = 20
    ) {
        self.text = text
        self.scope = scope
        self.prefixMatchesLastToken = prefixMatchesLastToken
        self.limit = limit
    }
}

public protocol NoteIndexing: AnyObject {
    /// Throws `NoteIndexMissingRowError` if `note.id` has no row in `notes`
    /// yet — an embedding written against a phantom id could never be read
    /// back by anything joining through the real row.
    func index(_ note: WriterNote) throws
    func remove(_ id: NoteID) throws
    func search(_ query: NoteQuery) throws -> [NoteHit]
    /// Pen's continuous matcher: what the text under the caret is about.
    func related(to windowText: String, in document: DocumentID, limit: Int) throws -> [NoteHit]
    func rebuild() throws
}

/// `index(_:)` was asked to index a note whose row `notes` does not have.
public struct NoteIndexMissingRowError: Error, Equatable {
    public let id: NoteID
}

/// `notes_fts` (external content over `notes`, kept in step by triggers) plus
/// `note_embeddings`.
///
/// A search takes its candidates from FTS and then re-scores them: the words
/// decide what is even considered, the meaning decides the order. Fusion is
/// skipped under three tokens, where a query is too short for a sentence
/// vector to say anything the words did not.
public final class SQLiteNoteIndex: NoteIndexing {

    /// Tokens below which the score is lexical only.
    static let fusionTokenThreshold = 3
    /// How much of the trailing window is embedded a second time, so a note
    /// about the sentence being typed is not lost inside a long paragraph.
    static let relatedTailLength = 120
    /// Candidates pulled per requested hit, so re-scoring has room to reorder.
    static let candidateMultiplier = 4

    private let database: WriterDatabase
    private let embedding: SentenceEmbedding?

    public init(database: WriterDatabase, embedding: SentenceEmbedding? = nil) {
        self.database = database
        self.embedding = embedding
    }

    // MARK: - Maintenance

    /// `notes_fts`'s own triggers keep it exact whenever `notes.text`
    /// changes, so indexing only ever has embeddings left to write.
    public func index(_ note: WriterNote) throws {
        let vector = embedding?.vector(for: note.text)
        try database.transaction { db in
            try Self.applyEmbedding(vector, for: note.id, embedding: self.embedding, in: db)
        }
    }

    public func remove(_ id: NoteID) throws {
        try database.transaction { db in
            try db.run(
                "INSERT INTO notes_fts(notes_fts, rowid, text)"
                + " SELECT 'delete', rowid, text FROM notes WHERE id = ?"
            ) { statement in
                try statement.bind(1, id.rawValue.uuidString)
            }
            try db.run("DELETE FROM note_embeddings WHERE note_id = ?") { statement in
                try statement.bind(1, id.rawValue.uuidString)
            }
        }
    }

    /// Repairs a drifted index from `notes` itself. The embedding half is
    /// skipped — never destroyed — when this index has no working embedding
    /// model: a build without on-device embeddings, or a language the model
    /// does not cover, must not erase vectors a later build could still use.
    public func rebuild() throws {
        var notes: [(NoteID, String)] = []
        try database.perform { db in
            try db.query("SELECT id, text FROM notes") { row in
                guard let uuid = row.uuid(0) else { return }
                notes.append((NoteID(uuid), row.string(1) ?? ""))
            }
        }
        try database.transaction { db in
            try db.execute("INSERT INTO notes_fts(notes_fts) VALUES('rebuild')")
            guard let embedding, embedding.dimensions > 0 else { return }
            try db.execute("DELETE FROM note_embeddings")
            for (id, text) in notes {
                try Self.applyEmbedding(embedding.vector(for: text), for: id, embedding: embedding, in: db)
            }
        }
    }

    /// Writes (or clears) one note's embedding row. Throws when `id` has no
    /// row in `notes`: `note_embeddings.note_id` references it, so a write
    /// against a missing row would only surface as an opaque foreign-key
    /// failure instead of naming the note.
    private static func applyEmbedding(
        _ vector: [Float]?, for id: NoteID, embedding: SentenceEmbedding?, in db: WriterDatabase
    ) throws {
        guard try db.scalarInt("SELECT 1 FROM notes WHERE id = ?", { statement in
            try statement.bind(1, id.rawValue.uuidString)
        }) != nil else {
            throw NoteIndexMissingRowError(id: id)
        }
        guard let vector, let embedding else { return }
        try db.run(
            "INSERT INTO note_embeddings (note_id, model_version, dims, vector)"
            + " VALUES (?, ?, ?, ?) ON CONFLICT(note_id) DO UPDATE SET"
            + " model_version = excluded.model_version, dims = excluded.dims,"
            + " vector = excluded.vector"
        ) { statement in
            try statement.bind(1, id.rawValue.uuidString)
            try statement.bind(2, embedding.modelVersion)
            try statement.bind(3, vector.count)
            try statement.bind(4, blob: VectorBlob.encode(vector))
        }
    }

    // MARK: - Search

    public func search(_ query: NoteQuery) throws -> [NoteHit] {
        let tokens = FTSQuery.tokens(query.text)
        guard let match = FTSQuery.make(
            query.text, prefixMatchesLastToken: query.prefixMatchesLastToken) else { return [] }
        let queryVector = tokens.count >= Self.fusionTokenThreshold
            ? embedding?.vector(for: query.text) : nil

        var sql = """
            SELECT n.id, snippet(notes_fts, 0, '', '', '…', 12), bm25(notes_fts) AS rank,
                e.vector, e.dims, n.text,
                (SELECT group_concat(document_id, ',') FROM note_documents WHERE note_id = n.id)
            FROM notes_fts
            JOIN notes n ON n.rowid = notes_fts.rowid
            LEFT JOIN note_embeddings e ON e.note_id = n.id
            WHERE notes_fts MATCH ?
            """
        var scopeDocumentID: String?
        if case .document(let id) = query.scope {
            sql += " AND n.id IN (SELECT note_id FROM note_documents WHERE document_id = ?)"
            scopeDocumentID = id.rawValue.uuidString
        }
        sql += " ORDER BY rank ASC LIMIT ?"

        var hits: [(hit: NoteHit, rank: Int)] = []
        try database.perform { db in
            try db.query(sql, { statement in
                var index: Int32 = 1
                try statement.bind(index, match); index += 1
                if let scopeDocumentID {
                    try statement.bind(index, scopeDocumentID); index += 1
                }
                try statement.bind(index, max(1, query.limit * Self.candidateMultiplier))
            }, row: { row in
                guard let uuid = row.uuid(0) else { return }
                let bm25 = row.double(2) ?? 0
                let score: Double
                if let queryVector,
                   let vector = VectorBlob.decode(row.blob(3), count: row.int(4)) {
                    score = HybridScorer.fuse(
                        cosine: VectorBlob.cosine(queryVector, vector), bm25Rank: bm25)
                } else {
                    score = HybridScorer.lexical(bm25Rank: bm25)
                }
                hits.append((NoteHit(
                    noteID: NoteID(uuid), score: score, snippet: row.string(1) ?? "",
                    noteText: row.string(5) ?? "", documentIDs: Self.documentIDs(row.string(6))),
                    hits.count))
            })
        }
        // Ties keep the order bm25 gave them, so a repeated search answers the
        // same way twice.
        return Array(hits
            .sorted { $0.hit.score == $1.hit.score ? $0.rank < $1.rank : $0.hit.score > $1.hit.score }
            .map(\.hit)
            .prefix(max(0, query.limit)))
    }

    /// The sheets a note sits on, from `group_concat` over `note_documents`.
    /// The "@" overlay reads these to say whether a hit is from another sheet.
    private static func documentIDs(_ joined: String?) -> [DocumentID] {
        (joined ?? "").split(separator: ",").compactMap { UUID(uuidString: String($0)) }.map { DocumentID($0) }
    }

    public func related(to windowText: String, in document: DocumentID, limit: Int) throws -> [NoteHit] {
        guard let embedding else { return [] }
        let trimmed = windowText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // Two contexts: the whole trailing window, and its tail. A note about
        // the sentence just typed loses to the paragraph's general subject
        // unless the tail is scored on its own.
        let tail = String(trimmed.suffix(Self.relatedTailLength))
        let vectors = [embedding.vector(for: trimmed), embedding.vector(for: tail)].compactMap { $0 }
        guard !vectors.isEmpty else { return [] }

        var hits: [(hit: NoteHit, rank: Int)] = []
        try database.perform { db in
            try db.query(
                """
                SELECT n.id, n.text, e.vector, e.dims
                FROM note_embeddings e
                JOIN notes n ON n.id = e.note_id
                JOIN note_documents nd ON nd.note_id = n.id
                WHERE nd.document_id = ?
                """,
                { statement in try statement.bind(1, document.rawValue.uuidString) },
                row: { row in
                    guard let uuid = row.uuid(0),
                          let vector = VectorBlob.decode(row.blob(2), count: row.int(3)) else { return }
                    let best = vectors
                        .map { HybridScorer.rescale(cosine: VectorBlob.cosine($0, vector)) }
                        .max() ?? 0
                    hits.append((NoteHit(
                        noteID: NoteID(uuid), score: best,
                        snippet: String((row.string(1) ?? "").prefix(160)),
                        noteText: row.string(1) ?? "", documentIDs: [document]), hits.count))
                })
        }
        return Array(hits
            .sorted { $0.hit.score == $1.hit.score ? $0.rank < $1.rank : $0.hit.score > $1.hit.score }
            .map(\.hit)
            .prefix(max(0, limit)))
    }
}

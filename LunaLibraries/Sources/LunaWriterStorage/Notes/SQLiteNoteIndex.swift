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
    func index(_ note: WriterNote) throws
    func remove(_ id: NoteID) throws
    func search(_ query: NoteQuery) throws -> [NoteHit]
    /// Pen's continuous matcher: what the text under the caret is about.
    func related(to windowText: String, in document: DocumentID, limit: Int) throws -> [NoteHit]
    func rebuild() throws
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

    public func index(_ note: WriterNote) throws {
        let vector = embedding?.vector(for: note.text)
        try database.transaction { db in
            try Self.refreshFTS(for: note.id, in: db)
            guard let vector, let embedding = self.embedding else { return }
            try db.run(
                "INSERT INTO note_embeddings (note_id, model_version, dims, vector)"
                + " VALUES (?, ?, ?, ?) ON CONFLICT(note_id) DO UPDATE SET"
                + " model_version = excluded.model_version, dims = excluded.dims,"
                + " vector = excluded.vector"
            ) { statement in
                try statement.bind(1, note.id.rawValue.uuidString)
                try statement.bind(2, embedding.modelVersion)
                try statement.bind(3, vector.count)
                try statement.bind(4, blob: VectorBlob.encode(vector))
            }
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
            try db.execute("DELETE FROM note_embeddings")
        }
        guard embedding != nil else { return }
        for (id, text) in notes {
            try index(WriterNote(id: id, text: text))
        }
    }

    /// The insert trigger already indexed the note; re-indexing removes that
    /// row first so a re-index cannot leave two copies behind.
    private static func refreshFTS(for id: NoteID, in db: WriterDatabase) throws {
        try db.run(
            "INSERT INTO notes_fts(notes_fts, rowid, text)"
            + " SELECT 'delete', rowid, text FROM notes WHERE id = ?"
        ) { statement in
            try statement.bind(1, id.rawValue.uuidString)
        }
        try db.run(
            "INSERT INTO notes_fts(rowid, text) SELECT rowid, text FROM notes WHERE id = ?"
        ) { statement in
            try statement.bind(1, id.rawValue.uuidString)
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
            SELECT n.id, snippet(notes_fts, 0, '', '', '…', 12), bm25(notes_fts), e.vector, e.dims
            FROM notes_fts
            JOIN notes n ON n.rowid = notes_fts.rowid
            LEFT JOIN note_embeddings e ON e.note_id = n.id
            WHERE notes_fts MATCH ?
            """
        if case .document(let id) = query.scope {
            sql += " AND n.id IN (SELECT note_id FROM note_documents WHERE document_id = '"
                + id.rawValue.uuidString + "')"
        }
        sql += " ORDER BY bm25(notes_fts) ASC LIMIT ?"

        var hits: [(hit: NoteHit, rank: Int)] = []
        try database.perform { db in
            try db.query(sql, { statement in
                try statement.bind(1, match)
                try statement.bind(2, max(1, query.limit * Self.candidateMultiplier))
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
                    noteID: NoteID(uuid), score: score, snippet: row.string(1) ?? ""),
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
                        snippet: String((row.string(1) ?? "").prefix(160))), hits.count))
                })
        }
        return Array(hits
            .sorted { $0.hit.score == $1.hit.score ? $0.rank < $1.rank : $0.hit.score > $1.hit.score }
            .map(\.hit)
            .prefix(max(0, limit)))
    }
}

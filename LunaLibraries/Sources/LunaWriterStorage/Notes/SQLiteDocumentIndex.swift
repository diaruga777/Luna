import Foundation

/// What the note router searches to decide where a note belongs, and what the
/// library's own search reads.
public protocol DocumentIndexing: AnyObject {
    /// The caller passes the sheet's text: a contentless index stores no
    /// column values, so it cannot recover a body it is not given.
    func index(_ document: WriterDocument, body: String) throws
    func remove(_ id: DocumentID) throws
    func search(_ text: String, limit: Int) throws -> [DocumentHit]
}

/// `documents_fts` plus `document_embeddings`.
///
/// The FTS table is contentless: a sheet's body is a `.md` file, so there is
/// nothing for SQLite to mirror and the index carries only its own postings.
/// The embedding is over title, snippet and keywords — what a sheet is about,
/// not everything it says — so a long sheet does not drown a short one.
public final class SQLiteDocumentIndex: DocumentIndexing {
    private let database: WriterDatabase
    private let embedding: SentenceEmbedding?

    public init(database: WriterDatabase, embedding: SentenceEmbedding? = nil) {
        self.database = database
        self.embedding = embedding
    }

    public func index(_ document: WriterDocument, body: String) throws {
        let summary = Self.summary(of: document)
        let vector = embedding?.vector(for: summary)
        try database.transaction { db in
            guard let rowID = try Self.rowID(of: document.id, in: db) else { return }
            try db.run("DELETE FROM documents_fts WHERE rowid = ?") { statement in
                try statement.bind(1, rowID)
            }
            try db.run("INSERT INTO documents_fts (rowid, title, body) VALUES (?, ?, ?)") { statement in
                try statement.bind(1, rowID)
                try statement.bind(2, Self.titleTerms(of: document))
                try statement.bind(3, body)
            }
            guard let vector, let embedding = self.embedding else { return }
            try db.run(
                "INSERT INTO document_embeddings (document_id, model_version, dims, vector)"
                + " VALUES (?, ?, ?, ?) ON CONFLICT(document_id) DO UPDATE SET"
                + " model_version = excluded.model_version, dims = excluded.dims,"
                + " vector = excluded.vector"
            ) { statement in
                try statement.bind(1, document.id.rawValue.uuidString)
                try statement.bind(2, embedding.modelVersion)
                try statement.bind(3, vector.count)
                try statement.bind(4, blob: VectorBlob.encode(vector))
            }
        }
    }

    public func remove(_ id: DocumentID) throws {
        try database.transaction { db in
            if let rowID = try Self.rowID(of: id, in: db) {
                try db.run("DELETE FROM documents_fts WHERE rowid = ?") { statement in
                    try statement.bind(1, rowID)
                }
            }
            try db.run("DELETE FROM document_embeddings WHERE document_id = ?") { statement in
                try statement.bind(1, id.rawValue.uuidString)
            }
        }
    }

    public func search(_ text: String, limit: Int) throws -> [DocumentHit] {
        let tokens = FTSQuery.tokens(text)
        guard let match = FTSQuery.make(text, prefixMatchesLastToken: false) else { return [] }
        let queryVector = tokens.count >= 3 ? embedding?.vector(for: text) : nil
        let candidates = try DocumentFTSSearch.candidates(
            match: match, limit: max(limit * 4, limit), in: database)
        let hits = candidates.enumerated().map { rank, candidate -> (hit: DocumentHit, rank: Int) in
            guard let queryVector,
                  let vector = VectorBlob.decode(candidate.vector, count: candidate.dims) else {
                return (DocumentHit(
                    documentID: candidate.id,
                    score: HybridScorer.lexical(bm25Rank: candidate.bm25)), rank)
            }
            return (DocumentHit(
                documentID: candidate.id,
                score: HybridScorer.fuse(
                    cosine: VectorBlob.cosine(queryVector, vector), bm25Rank: candidate.bm25)), rank)
        }
        // Ties keep the order bm25 gave them, so a repeated search answers the
        // same way twice.
        return Array(hits
            .sorted { $0.hit.score == $1.hit.score ? $0.rank < $1.rank : $0.hit.score > $1.hit.score }
            .map(\.hit)
            .prefix(max(0, limit)))
    }

    /// A sheet's title carries most of the signal, so it is repeated: FTS5
    /// weighs term frequency, and a title term should outrank the same term
    /// buried in the body.
    static func titleTerms(of document: WriterDocument) -> String {
        ([document.title, document.title, document.snippet] + document.keywords)
            .joined(separator: " ")
    }

    static func summary(of document: WriterDocument) -> String {
        ([document.title, document.snippet] + document.keywords)
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }

    static func rowID(of id: DocumentID, in db: WriterDatabase) throws -> Int64? {
        try db.scalarInt("SELECT rowid FROM documents WHERE id = ?") { statement in
            try statement.bind(1, id.rawValue.uuidString)
        }
    }
}

/// The one `documents_fts` query. The library's plain search and the router's
/// fused search read the same rows; only the scoring differs.
enum DocumentFTSSearch {
    struct Candidate {
        let id: DocumentID
        let bm25: Double
        let vector: Data?
        let dims: Int
    }

    static func candidates(match: String, limit: Int, in database: WriterDatabase) throws -> [Candidate] {
        try database.perform { db in
            var result: [Candidate] = []
            try db.query(
                """
                SELECT d.id, bm25(documents_fts), e.vector, e.dims
                FROM documents_fts
                JOIN documents d ON d.rowid = documents_fts.rowid
                LEFT JOIN document_embeddings e ON e.document_id = d.id
                WHERE documents_fts MATCH ? AND d.trashed_at IS NULL
                ORDER BY bm25(documents_fts) ASC LIMIT ?
                """,
                { statement in
                    try statement.bind(1, match)
                    try statement.bind(2, max(1, limit))
                },
                row: { row in
                    guard let uuid = row.uuid(0) else { return }
                    result.append(Candidate(
                        id: DocumentID(uuid), bm25: row.double(1) ?? 0,
                        vector: row.blob(2), dims: row.int(3)))
                })
            return result
        }
    }
}

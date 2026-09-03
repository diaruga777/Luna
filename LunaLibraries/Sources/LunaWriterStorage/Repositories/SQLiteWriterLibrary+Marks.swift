import Foundation
import LunaWriterModels

extension SQLiteWriterLibrary {

    public func marks(for document: DocumentID) throws -> DocumentMarks {
        try database.perform { db in
            var annotations: [Annotation] = []
            try db.query(
                "SELECT id, kind, source, note_id, anchor_start, anchor_end, anchor_exact,"
                + " anchor_prefix, anchor_suffix, created_at FROM annotations"
                + " WHERE document_id = ? ORDER BY anchor_start ASC",
                { statement in try statement.bind(1, document.rawValue.uuidString) },
                row: { row in
                    guard let uuid = row.uuid(0) else { return }
                    annotations.append(Annotation(
                        id: AnnotationID(uuid), documentID: document,
                        // No CHECK on either column: an unknown kind reads as a
                        // plain comment, an unknown source as a manual one.
                        kind: Annotation.Kind(rawValue: row.string(1) ?? "") ?? .comment,
                        source: Annotation.Source(rawValue: row.string(2) ?? "") ?? .manual,
                        noteID: row.uuid(3).map(NoteID.init),
                        anchor: TextAnchor(
                            start: row.int(4), end: row.int(5), exact: row.string(6) ?? "",
                            prefix: row.string(7) ?? "", suffix: row.string(8) ?? ""),
                        createdAt: row.date(9) ?? Date()))
                })
            var authorship: [AuthorshipSpan] = []
            try db.query(
                "SELECT start, end_offset, source, model, created_at FROM authorship_spans"
                + " WHERE document_id = ? ORDER BY start ASC",
                { statement in try statement.bind(1, document.rawValue.uuidString) },
                row: { row in
                    authorship.append(AuthorshipSpan(
                        range: TextRange(start: row.int(0), end: row.int(1)),
                        source: Self.authorshipSource(row.string(2), model: row.string(3)),
                        createdAt: row.date(4) ?? Date()))
                })
            return DocumentMarks(annotations: annotations, authorship: authorship)
        }
    }

    public func replaceMarks(_ marks: DocumentMarks, for document: DocumentID) throws {
        try database.transaction { db in
            try db.run("DELETE FROM annotations WHERE document_id = ?") { statement in
                try statement.bind(1, document.rawValue.uuidString)
            }
            for annotation in marks.annotations {
                try db.run(
                    """
                    INSERT INTO annotations (id, document_id, kind, source, note_id, anchor_start,
                        anchor_end, anchor_exact, anchor_prefix, anchor_suffix, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """
                ) { statement in
                    try statement.bind(1, annotation.id.rawValue.uuidString)
                    try statement.bind(2, document.rawValue.uuidString)
                    try statement.bind(3, annotation.kind.rawValue)
                    try statement.bind(4, annotation.source.rawValue)
                    try statement.bind(5, annotation.noteID?.rawValue.uuidString)
                    try statement.bind(6, annotation.anchor.start)
                    try statement.bind(7, annotation.anchor.end)
                    try statement.bind(8, annotation.anchor.exact)
                    try statement.bind(9, annotation.anchor.prefix)
                    try statement.bind(10, annotation.anchor.suffix)
                    try statement.bind(11, date: annotation.createdAt)
                }
            }
            try db.run("DELETE FROM authorship_spans WHERE document_id = ?") { statement in
                try statement.bind(1, document.rawValue.uuidString)
            }
            for span in marks.authorship {
                let (source, model) = Self.authorshipColumns(span.source)
                try db.run(
                    "INSERT INTO authorship_spans"
                    + " (document_id, start, end_offset, source, model, created_at)"
                    + " VALUES (?, ?, ?, ?, ?, ?)"
                ) { statement in
                    try statement.bind(1, document.rawValue.uuidString)
                    try statement.bind(2, span.range.start)
                    try statement.bind(3, span.range.end)
                    try statement.bind(4, source)
                    try statement.bind(5, model)
                    try statement.bind(6, date: span.createdAt)
                }
            }
        }
        changes.post(.document(document))
    }

    // MARK: - Snapshots

    public func recordSnapshot(_ text: String, for document: DocumentID) throws {
        try database.transaction { db in
            try db.run(
                "INSERT INTO document_snapshots (document_id, created_at, text) VALUES (?, ?, ?)"
            ) { statement in
                try statement.bind(1, document.rawValue.uuidString)
                try statement.bind(2, date: Date())
                try statement.bind(3, text)
            }
            // Keeping the newest by rowid, not by created_at: two snapshots
            // taken in the same millisecond still have an order.
            try db.run(
                """
                DELETE FROM document_snapshots WHERE document_id = ? AND rowid NOT IN (
                    SELECT rowid FROM document_snapshots WHERE document_id = ?
                    ORDER BY created_at DESC, rowid DESC LIMIT ?)
                """
            ) { statement in
                try statement.bind(1, document.rawValue.uuidString)
                try statement.bind(2, document.rawValue.uuidString)
                try statement.bind(3, DocumentSnapshotLimit.perDocument)
            }
        }
    }

    /// Snapshots kept for `document`, without reading any of their text.
    public func snapshotCount(for document: DocumentID) throws -> Int {
        try database.perform { db in
            Int((try db.scalarInt(
                "SELECT COUNT(*) FROM document_snapshots WHERE document_id = ?"
            ) { statement in
                try statement.bind(1, document.rawValue.uuidString)
            }) ?? 0)
        }
    }

    /// Metadata only — when and how long — for a list that shows one
    /// snapshot's text on demand rather than loading every one up front.
    public func snapshotSummaries(for document: DocumentID) throws -> [DocumentSnapshotSummary] {
        try database.perform { db in
            var result: [DocumentSnapshotSummary] = []
            try db.query(
                "SELECT created_at, length(text) FROM document_snapshots WHERE document_id = ?"
                + " ORDER BY created_at DESC, rowid DESC",
                { statement in try statement.bind(1, document.rawValue.uuidString) },
                row: { row in
                    result.append(DocumentSnapshotSummary(
                        documentID: document, createdAt: row.date(0) ?? Date(),
                        characterCount: row.int(1)))
                })
            return result
        }
    }

    public func snapshots(for document: DocumentID) throws -> [DocumentSnapshot] {
        try database.perform { db in
            var result: [DocumentSnapshot] = []
            try db.query(
                "SELECT created_at, text FROM document_snapshots WHERE document_id = ?"
                + " ORDER BY created_at DESC, rowid DESC",
                { statement in try statement.bind(1, document.rawValue.uuidString) },
                row: { row in
                    result.append(DocumentSnapshot(
                        documentID: document, createdAt: row.date(0) ?? Date(),
                        text: row.string(1) ?? ""))
                })
            return result
        }
    }

    // MARK: - Authorship column mapping

    /// `.ai` needs the model name beside the source, so the pair is stored in
    /// two columns and read back through one place.
    static func authorshipSource(_ raw: String?, model: String?) -> AuthorshipSpan.Source {
        switch raw {
        case "pasted": return .pasted
        case "ai": return .ai(model: model ?? "")
        default: return .author
        }
    }

    static func authorshipColumns(_ source: AuthorshipSpan.Source) -> (String, String?) {
        switch source {
        case .author: return ("author", nil)
        case .pasted: return ("pasted", nil)
        case .ai(let model): return ("ai", model)
        }
    }
}

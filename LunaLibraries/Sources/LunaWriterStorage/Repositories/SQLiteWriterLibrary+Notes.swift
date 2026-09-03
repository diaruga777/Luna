import Foundation

extension SQLiteWriterLibrary {

    static let noteColumns =
        "id, text, source, anchor_document_id, anchor_start, anchor_end, anchor_exact,"
        + " anchor_prefix, anchor_suffix, created_at, updated_at"

    public func notes(for document: DocumentID) throws -> [WriterNote] {
        try loadNotes(
            "SELECT \(Self.noteColumns) FROM notes"
            + " WHERE id IN (SELECT note_id FROM note_documents WHERE document_id = ?)"
            + " ORDER BY created_at ASC"
        ) { statement in
            try statement.bind(1, document.rawValue.uuidString)
        }
    }

    public func unattachedNotes() throws -> [WriterNote] {
        try loadNotes(
            "SELECT \(Self.noteColumns) FROM notes"
            + " WHERE id NOT IN (SELECT note_id FROM note_documents) ORDER BY created_at DESC")
    }

    public func note(_ id: NoteID) throws -> WriterNote? {
        try loadNotes("SELECT \(Self.noteColumns) FROM notes WHERE id = ?") { statement in
            try statement.bind(1, id.rawValue.uuidString)
        }.first
    }

    public func insert(_ note: WriterNote) throws {
        try database.transaction { db in
            try db.run(
                """
                INSERT INTO notes (id, text, source, anchor_document_id, anchor_start, anchor_end,
                    anchor_exact, anchor_prefix, anchor_suffix, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
            ) { statement in try Self.bindNote(note, to: statement) }
            for document in note.documentIDs {
                try Self.attach(note.id, to: document, attachment: .manual, in: db)
            }
        }
        changes.post(.notes(note.documentIDs.first))
    }

    public func update(_ note: WriterNote) throws {
        try database.transaction { db in
            try db.run(
                """
                UPDATE notes SET text = ?, source = ?, anchor_document_id = ?, anchor_start = ?,
                    anchor_end = ?, anchor_exact = ?, anchor_prefix = ?, anchor_suffix = ?,
                    updated_at = ? WHERE id = ?
                """
            ) { statement in
                try statement.bind(1, note.text)
                try statement.bind(2, note.source.rawValue)
                try statement.bind(3, note.anchor == nil ? nil : note.documentIDs.first?.rawValue.uuidString)
                try statement.bind(4, int: note.anchor?.start)
                try statement.bind(5, int: note.anchor?.end)
                try statement.bind(6, note.anchor?.exact)
                try statement.bind(7, note.anchor?.prefix)
                try statement.bind(8, note.anchor?.suffix)
                try statement.bind(9, date: Date())
                try statement.bind(10, note.id.rawValue.uuidString)
            }
        }
        changes.post(.notes(note.documentIDs.first))
    }

    public func delete(_ id: NoteID) throws {
        try database.transaction { db in
            try db.run("DELETE FROM notes WHERE id = ?") { statement in
                try statement.bind(1, id.rawValue.uuidString)
            }
        }
        changes.post(.notes(nil))
    }

    public func attach(_ id: NoteID, to document: DocumentID, attachment: NoteAttachment) throws {
        try database.transaction { db in
            try Self.attach(id, to: document, attachment: attachment, in: db)
        }
        changes.post(.notes(document))
    }

    public func detach(_ id: NoteID, from document: DocumentID) throws {
        try database.transaction { db in
            try db.run("DELETE FROM note_documents WHERE note_id = ? AND document_id = ?") { statement in
                try statement.bind(1, id.rawValue.uuidString)
                try statement.bind(2, document.rawValue.uuidString)
            }
        }
        changes.post(.notes(document))
    }

    private static func attach(
        _ id: NoteID, to document: DocumentID, attachment: NoteAttachment, in db: WriterDatabase
    ) throws {
        try db.run(
            "INSERT INTO note_documents (note_id, document_id, attachment) VALUES (?, ?, ?)"
            + " ON CONFLICT(note_id, document_id) DO UPDATE SET attachment = excluded.attachment"
        ) { statement in
            try statement.bind(1, id.rawValue.uuidString)
            try statement.bind(2, document.rawValue.uuidString)
            try statement.bind(3, attachment.rawValue)
        }
    }

    private static func bindNote(_ note: WriterNote, to statement: WriterStatement) throws {
        try statement.bind(1, note.id.rawValue.uuidString)
        try statement.bind(2, note.text)
        try statement.bind(3, note.source.rawValue)
        try statement.bind(4, note.anchor == nil ? nil : note.documentIDs.first?.rawValue.uuidString)
        try statement.bind(5, int: note.anchor?.start)
        try statement.bind(6, int: note.anchor?.end)
        try statement.bind(7, note.anchor?.exact)
        try statement.bind(8, note.anchor?.prefix)
        try statement.bind(9, note.anchor?.suffix)
        try statement.bind(10, date: note.createdAt)
        try statement.bind(11, date: note.updatedAt)
    }

    func loadNotes(
        _ sql: String, _ bind: (WriterStatement) throws -> Void = { _ in }
    ) throws -> [WriterNote] {
        try database.perform { db in
            var notes: [WriterNote] = []
            try db.query(sql, bind) { row in
                guard let uuid = row.uuid(0) else { return }
                var anchor: TextAnchor?
                if let start = row.intOrNil(4), let end = row.intOrNil(5) {
                    anchor = TextAnchor(
                        start: start, end: end, exact: row.string(6) ?? "",
                        prefix: row.string(7) ?? "", suffix: row.string(8) ?? "")
                }
                notes.append(WriterNote(
                    id: NoteID(uuid), documentIDs: [], text: row.string(1) ?? "",
                    // No CHECK on the column: an unknown source reads as typed.
                    source: WriterNote.Source(rawValue: row.string(2) ?? "") ?? .typed,
                    anchor: anchor,
                    createdAt: row.date(9) ?? Date(), updatedAt: row.date(10) ?? Date()))
            }
            guard !notes.isEmpty else { return [] }
            var attachments: [NoteID: [DocumentID]] = [:]
            let ids = notes.map { "'\($0.id.rawValue.uuidString)'" }.joined(separator: ",")
            try db.query(
                "SELECT note_id, document_id FROM note_documents WHERE note_id IN (\(ids))"
            ) { row in
                guard let note = row.uuid(0), let document = row.uuid(1) else { return }
                attachments[NoteID(note), default: []].append(DocumentID(document))
            }
            return notes.map { note in
                var copy = note
                copy.documentIDs = attachments[note.id] ?? []
                return copy
            }
        }
    }
}

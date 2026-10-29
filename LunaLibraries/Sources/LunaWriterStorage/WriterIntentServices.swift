import Foundation
import LunaWriterModels

/// Where a note ended up, so the intent can say so out loud.
public enum NoteAddResult: Equatable, Sendable {
    case document(WriterDocument)
    case inbox
}

/// The Foundation API the App Intents call. The intent definitions live in the
/// app target because the metadata processor reads them there; everything they
/// do is here, where it can be tested without a shortcut.
public final class WriterIntentServices {

    public enum Failure: LocalizedError, Equatable {
        case emptyNote, missingDocument, missingNote, invalidGroup
        public var errorDescription: String? {
            switch self {
            case .emptyNote: return "Enter some text for the note."
            case .missingDocument: return "This sheet is no longer available."
            case .missingNote: return "This note is no longer available."
            case .invalidGroup: return "Choose a folder in your library."
            }
        }
    }

    /// Sheets `recentDocuments` looks back over.
    public static let recentWindowDays = 90

    private let library: WriterLibraryStoring
    private let notes: NoteStoring
    private let textStore: DocumentTextStoring
    private let router: NoteRouting?

    public init(
        library: WriterLibraryStoring, notes: NoteStoring,
        textStore: DocumentTextStoring, router: NoteRouting?
    ) {
        self.library = library
        self.notes = notes
        self.textStore = textStore
        self.router = router
    }

    /// Files a capture. Named a sheet, it goes there whole. Named nothing, it
    /// is split and each piece is routed on its own; with no router it waits
    /// unattached in the Inbox. `notes.insert` indexes each note itself.
    @discardableResult
    public func addNote(text: String, to document: DocumentID?) throws -> NoteAddResult {
        try captureNote(text: text, to: document).destination
    }

    public func captureNote(text: String, to document: DocumentID?) throws -> (destination: NoteAddResult, notes: [WriterNote]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyNote }
        if let document {
            guard let target = try library.document(document), target.trashedAt == nil else { throw Failure.missingDocument }
            let note = WriterNote(documentIDs: [target.id], text: trimmed, source: .intent)
            try notes.insert(note)
            return (.document(target), [note])
        }
        guard let router else {
            let note = WriterNote(text: trimmed, source: .intent)
            try notes.insert(note)
            return (.inbox, [note])
        }
        var first: WriterDocument?
        var captured: [WriterNote] = []
        for piece in NoteCaptureSplitter.split(trimmed) {
            let placements = try router.route(piece)
            let note = WriterNote(text: piece, source: .intent)
            try notes.insert(note)
            for placement in placements {
                try notes.attach(note.id, to: placement.document.id, attachment: placement.created ? .created : .routed)
                if first == nil { first = placement.document }
            }
            if let stored = try notes.note(note.id) { captured.append(stored) }
        }
        return (first.map(NoteAddResult.document) ?? .inbox, captured)
    }

    @discardableResult
    public func createDocument(title: String?, text: String?, in group: GroupID?) throws -> WriterDocument {
        if let group {
            guard try library.groups().contains(where: { $0.id == group && $0.kind != .trash }) else { throw Failure.invalidGroup }
        }
        var document = try library.createDocument(
            in: group ?? library.inboxGroupID, title: title)
        let heading = title.flatMap { $0.isEmpty ? nil : "# \($0)\n\n" } ?? ""
        try textStore.saveText(heading + (text ?? ""), for: &document)
        return document
    }

    /// One sheet by id, for entity lookup. Trashed sheets stay findable so a
    /// shortcut that named one still resolves.
    public func document(_ id: DocumentID) throws -> WriterDocument? {
        try library.document(id)
    }

    public func findDocuments(search: String = "", id: DocumentID? = nil, modifiedAfter: Date? = nil, limit: Int = 50) throws -> [WriterDocument] {
        if let id { return try document(id).map { [$0] } ?? [] }
        return Array(try library.documents(matching: FilterPredicate(), scope: nil).filter {
            (search.isEmpty || $0.title.localizedStandardContains(search))
                && (modifiedAfter == nil || $0.updatedAt > modifiedAfter!)
        }.sorted { $0.updatedAt == $1.updatedAt ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString : $0.updatedAt > $1.updatedAt }.prefix(max(1, min(500, limit))))
    }

    public func text(for id: DocumentID) throws -> String {
        guard let document = try library.document(id) else { throw Failure.missingDocument }
        return try textStore.loadText(document)
    }

    public func findNotes(search: String = "", id: NoteID? = nil, document: DocumentID? = nil, limit: Int = 50) throws -> [WriterNote] {
        if let id { return try notes.note(id).map { [$0] } ?? [] }
        let values = try document.map { try notes.notes(for: $0) } ?? notes.allNotes()
        return Array(values.filter { search.isEmpty || $0.text.localizedStandardContains(search) }.prefix(max(1, min(500, limit))))
    }

    public func groups() throws -> [WriterGroup] { try library.groups() }

    public func createGroup(name: String) throws -> WriterGroup {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw Failure.invalidGroup }
        return try library.createGroup(name: name, icon: "folder", parent: nil, kind: .user)
    }

    public func updateNote(_ id: NoteID, text: String) throws -> WriterNote {
        guard var note = try notes.note(id) else { throw Failure.missingNote }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyNote }
        note.text = trimmed; note.updatedAt = Date()
        try notes.update(note)
        return note
    }

    public func deleteNotes(_ ids: [NoteID]) throws {
        guard try ids.allSatisfy({ try notes.note($0) != nil }) else { throw Failure.missingNote }
        for id in Set(ids) { try notes.delete(id) }
    }

    public func recentDocuments(limit: Int) throws -> [WriterDocument] {
        Array(try library.recent(days: Self.recentWindowDays).prefix(max(0, limit)))
    }

    /// Title search for the intent's entity query. Matches on the title alone,
    /// because a shortcut names a sheet rather than searching its text.
    public func documents(matchingTitle title: String) throws -> [WriterDocument] {
        let needle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return try recentDocuments(limit: 10) }
        return try library.documents(matchingTitle: needle, limit: 20)
    }
}

import Foundation

/// Where a note ended up, so the intent can say so out loud.
public enum NoteAddResult: Equatable, Sendable {
    case document(WriterDocument)
    case inbox
}

/// The Foundation API the App Intents call. The intent definitions live in the
/// app target because the metadata processor reads them there; everything they
/// do is here, where it can be tested without a shortcut.
public final class WriterIntentServices {

    /// Sheets `recentDocuments` looks back over.
    public static let recentWindowDays = 90

    private let library: WriterLibraryStoring
    private let notes: NoteStoring
    private let noteIndex: NoteIndexing
    private let textStore: DocumentTextStoring
    private let router: NoteRouting?

    public init(
        library: WriterLibraryStoring, notes: NoteStoring, noteIndex: NoteIndexing,
        textStore: DocumentTextStoring, router: NoteRouting?
    ) {
        self.library = library
        self.notes = notes
        self.noteIndex = noteIndex
        self.textStore = textStore
        self.router = router
    }

    /// Files a capture. Named a sheet, it goes there whole. Named nothing, it
    /// is split and each piece is routed on its own; with no router it waits
    /// unattached in the Inbox.
    @discardableResult
    public func addNote(text: String, to document: DocumentID?) throws -> NoteAddResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .inbox }

        if let document, let target = try library.document(document) {
            let note = WriterNote(documentIDs: [target.id], text: trimmed, source: .intent)
            try notes.insert(note)
            try notes.attach(note.id, to: target.id, attachment: .manual)
            try noteIndex.index(note)
            return .document(target)
        }

        guard let router else {
            let note = WriterNote(text: trimmed, source: .intent)
            try notes.insert(note)
            try noteIndex.index(note)
            return .inbox
        }

        var first: WriterDocument?
        for piece in NoteCaptureSplitter.split(trimmed) {
            let placements = try router.route(piece)
            let note = WriterNote(
                documentIDs: placements.map(\.documentID), text: piece, source: .intent)
            try notes.insert(note)
            for placement in placements {
                try notes.attach(
                    note.id, to: placement.documentID,
                    attachment: placement.created ? .created : .routed)
                if first == nil { first = try library.document(placement.documentID) }
            }
            try noteIndex.index(note)
        }
        guard let first else { return .inbox }
        return .document(first)
    }

    @discardableResult
    public func createDocument(title: String?, text: String?, in group: GroupID?) throws -> WriterDocument {
        var document = try library.createDocument(
            in: group ?? library.inboxGroupID, title: title)
        let heading = title.flatMap { $0.isEmpty ? nil : "# \($0)\n\n" } ?? ""
        try textStore.saveText(heading + (text ?? ""), for: &document)
        return document
    }

    public func recentDocuments(limit: Int) throws -> [WriterDocument] {
        Array(try library.recent(days: Self.recentWindowDays).prefix(max(0, limit)))
    }

    /// Title search for the intent's entity query. Matches on the title alone,
    /// because a shortcut names a sheet rather than searching its text.
    public func documents(matchingTitle title: String) throws -> [WriterDocument] {
        let needle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return try recentDocuments(limit: 10) }
        return try library.documents(matching: FilterPredicate(), scope: nil)
            .filter { $0.title.lowercased().contains(needle) }
    }
}

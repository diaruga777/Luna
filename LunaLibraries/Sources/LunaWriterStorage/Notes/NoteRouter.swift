import Foundation
import LunaWriterModels


public protocol NoteRouting: AnyObject {
    /// Decides which sheets a capture belongs to, creating one when no sheet
    /// is close enough. The caller writes the note and attaches it.
    func route(_ text: String) throws -> [NotePlacement]
}

/// Pen's deterministic router, made local.
///
/// Three steps, in order. An explicit phrase wins outright. Otherwise the
/// capture is searched against the sheet index and lands on EVERY sheet it
/// scores at least `attachThreshold` on — a thought can belong in two places,
/// and `note_documents` says so. With no sheet close enough it gets one of its
/// own in the Inbox, named from its first words.
public final class NoteRouter: NoteRouting {

    /// The fused score at which a sheet is close enough to file a note on.
    public static let attachThreshold = 0.45
    /// Sheets considered per capture.
    public static let candidateLimit = 5
    /// Words taken for the title of a sheet the router creates.
    public static let titleWordCount = 6

    private let library: WriterLibraryStoring
    private let documentIndex: DocumentIndexing

    public init(library: WriterLibraryStoring, documentIndex: DocumentIndexing) {
        self.library = library
        self.documentIndex = documentIndex
    }

    public func route(_ text: String) throws -> [NotePlacement] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let requested = ExplicitNewDocumentPhrase.match(trimmed) {
            let title = requested.isEmpty
                ? L10nWriterStorage.untitledDocumentTitle
                : TitleFromWords.make(requested, count: Self.titleWordCount)
            return [try createSheet(titled: title)]
        }

        let candidates = try documentIndex
            .search(trimmed, limit: Self.candidateLimit)
            .filter { $0.score >= Self.attachThreshold }
        if !candidates.isEmpty {
            return try candidates.compactMap { hit in
                guard let document = try library.document(hit.documentID) else { return nil }
                return NotePlacement(document: document, created: false)
            }
        }

        return [try createSheet(titled: TitleFromWords.make(trimmed, count: Self.titleWordCount))]
    }

    /// The new sheet is indexed before this returns, so a second capture in
    /// the same breath finds it instead of making another one.
    private func createSheet(titled title: String) throws -> NotePlacement {
        let document = try library.createDocument(in: library.inboxGroupID, title: title)
        try documentIndex.index(document, body: "")
        return NotePlacement(document: document, created: true)
    }
}

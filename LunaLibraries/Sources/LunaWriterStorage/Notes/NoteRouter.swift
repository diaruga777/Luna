import Foundation
import LunaWriterModels


public protocol NoteRouting: AnyObject {
    /// Decides which sheets a capture belongs to, creating one when no sheet
    /// is close enough. The caller writes the note and attaches it.
    func route(_ text: String) throws -> [NotePlacement]
}

/// Conservative semantic filing for captured notes.
///
/// Three steps, in order. An explicit phrase wins outright. Otherwise the
/// capture is compared with sheet meanings. Only a close match is automatic;
/// a second sheet needs stronger evidence and must be near the best match.
/// With no sheet close enough it gets its own in the Inbox, named from its
/// first words.
public final class NoteRouter: NoteRouting {

    /// Raw cosine, not a hybrid search score. Revision-1 English examples put
    /// unrelated captures around 0.16–0.33 and clear topic matches around 0.46–0.58.
    public static let attachThreshold = 0.42
    /// Multiple automatic links are exceptional, even when many sheets rank.
    public static let additionalAttachThreshold = 0.50
    public static let maximumScoreDrop = 0.04
    public static let maximumAttachments = 2
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
            .routingCandidates(trimmed, limit: Self.candidateLimit)
            .filter { $0.score >= Self.attachThreshold }
        if let best = candidates.first {
            let selected = candidates.enumerated().filter { index, hit in
                index == 0 || (hit.score >= Self.additionalAttachThreshold
                    && best.score - hit.score <= Self.maximumScoreDrop)
            }.prefix(Self.maximumAttachments)
            return try selected.compactMap { _, hit in
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

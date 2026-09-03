import Foundation

public struct NoteHit: Equatable, Sendable {
    public let noteID: NoteID
    public let score: Double
    public let snippet: String
    /// The note's own text, so a hit whose snippet is empty (FTS found no
    /// match to highlight) still has something to show without a second
    /// store read per row.
    public let noteText: String
    /// Every sheet the note is attached to, so telling "this note is also
    /// on another sheet" needs no second store read either.
    public let documentIDs: [DocumentID]

    public init(
        noteID: NoteID, score: Double, snippet: String,
        noteText: String = "", documentIDs: [DocumentID] = []
    ) {
        self.noteID = noteID
        self.score = score
        self.snippet = snippet
        self.noteText = noteText
        self.documentIDs = documentIDs
    }
}

public struct DocumentHit: Equatable, Sendable {
    public let documentID: DocumentID
    public let score: Double

    public init(documentID: DocumentID, score: Double) {
        self.documentID = documentID
        self.score = score
    }
}

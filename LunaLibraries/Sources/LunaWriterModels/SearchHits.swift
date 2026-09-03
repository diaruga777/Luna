import Foundation

public struct NoteHit: Equatable, Sendable {
    public let noteID: NoteID
    public let score: Double
    public let snippet: String

    public init(noteID: NoteID, score: Double, snippet: String) {
        self.noteID = noteID
        self.score = score
        self.snippet = snippet
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

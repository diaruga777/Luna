import Foundation

/// A mark over a range of a sheet. Read-along makes these from speech; the
/// editor menu makes them by hand.
public struct Annotation: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case needsWork, expand, cut, keep, comment
    }

    public enum Source: String, Codable, Sendable, CaseIterable {
        case voice, manual
    }

    public var id: AnnotationID
    public var documentID: DocumentID
    public var kind: Kind
    public var source: Source
    /// A `.comment` points at the note that holds its text.
    public var noteID: NoteID?
    public var anchor: TextAnchor
    public var createdAt: Date

    public init(
        id: AnnotationID = AnnotationID(),
        documentID: DocumentID,
        kind: Kind,
        source: Source = .manual,
        noteID: NoteID? = nil,
        anchor: TextAnchor,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.documentID = documentID
        self.kind = kind
        self.source = source
        self.noteID = noteID
        self.anchor = anchor
        self.createdAt = createdAt
    }
}

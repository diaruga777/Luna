import Foundation

/// A note. One note may belong to several sheets, because the router attaches
/// a captured note to every sheet that matches it.
public struct WriterNote: Codable, Equatable, Identifiable, Sendable {
    public enum Source: String, Codable, Sendable, CaseIterable {
        case typed, mention, intent, voice
    }

    public var id: NoteID
    /// Empty means unattached: the note lives in the Inbox.
    public var documentIDs: [DocumentID]
    public var text: String
    public var source: Source
    /// Where in the document the note was made.
    public var anchor: TextAnchor?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: NoteID = NoteID(),
        documentIDs: [DocumentID] = [],
        text: String,
        source: Source = .typed,
        anchor: TextAnchor? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.documentIDs = documentIDs
        self.text = text
        self.source = source
        self.anchor = anchor
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// How a note came to be attached to a sheet. Stored on the `note_documents`
/// join so the notes panel can say why a note is there.
public enum NoteAttachment: String, Codable, Sendable, CaseIterable {
    case routed, created, manual, mention, voice
}

/// Where the router put one captured note.
public struct NotePlacement: Equatable, Sendable {
    public let documentID: DocumentID
    public let title: String
    /// True when the router made the sheet for this note.
    public let created: Bool

    public init(documentID: DocumentID, title: String, created: Bool) {
        self.documentID = documentID
        self.title = title
        self.created = created
    }
}

//
//  ReadAlongMarkStore.swift
//  LunaWriterReadAlong
//

import Foundation
import LunaWriterModels
import LunaWriterStorage

/// The notes a spoken comment leaves behind. Marks themselves go through
/// `ReadAlongTextHosting` into the open session.
public final class ReadAlongMarkStore {

    public let documentID: DocumentID
    private let notes: NoteStoring

    public init(documentID: DocumentID, notes: NoteStoring) {
        self.documentID = documentID
        self.notes = notes
    }

    /// Stores a spoken remark as a note on this sheet.
    public func insertVoiceNote(text: String, anchor: TextAnchor) throws -> WriterNote {
        let note = WriterNote(
            documentIDs: [documentID], text: text, source: .voice, anchor: anchor)
        try notes.insert(note)
        try notes.attach(note.id, to: documentID, attachment: .voice)
        return note
    }

    public func note(_ id: NoteID) throws -> WriterNote? {
        try notes.note(id)
    }

    public func updateNote(_ note: WriterNote) throws {
        var edited = note
        edited.updatedAt = Date()
        try notes.update(edited)
    }

    public func deleteNote(_ id: NoteID) throws {
        try notes.delete(id)
    }
}

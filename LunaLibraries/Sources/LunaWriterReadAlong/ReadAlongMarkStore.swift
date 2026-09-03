//
//  ReadAlongMarkStore.swift
//  LunaWriterReadAlong
//

import Foundation
import LunaWriterModels
import LunaWriterStorage

/// The one place read-along writes to the sheet's marks and notes.
///
/// `DocumentMarksStoring` replaces a document's marks as a SET, so every edit
/// here is read-modify-write: the coordinator and the annotation popover both
/// go through this rather than each holding a copy of the list.
public final class ReadAlongMarkStore {

    public let documentID: DocumentID
    private let marks: DocumentMarksStoring
    private let notes: NoteStoring

    public init(documentID: DocumentID, marks: DocumentMarksStoring, notes: NoteStoring) {
        self.documentID = documentID
        self.marks = marks
        self.notes = notes
    }

    public func annotations() throws -> [Annotation] {
        try marks.marks(for: documentID).annotations
    }

    public func append(_ annotation: Annotation) throws {
        var current = try marks.marks(for: documentID)
        current.annotations.append(annotation)
        try marks.replaceMarks(current, for: documentID)
    }

    public func replace(_ annotation: Annotation) throws {
        var current = try marks.marks(for: documentID)
        guard let index = current.annotations.firstIndex(where: { $0.id == annotation.id })
        else { return }
        current.annotations[index] = annotation
        try marks.replaceMarks(current, for: documentID)
    }

    /// Removes the annotation, and the note a comment held. A comment with no
    /// note left behind would show an empty popover for ever.
    public func remove(_ id: AnnotationID) throws {
        var current = try marks.marks(for: documentID)
        guard let index = current.annotations.firstIndex(where: { $0.id == id }) else { return }
        let removed = current.annotations.remove(at: index)
        try marks.replaceMarks(current, for: documentID)
        if let noteID = removed.noteID { try notes.delete(noteID) }
    }

    /// Removes every annotation, and the notes their comments held.
    public func removeAll() throws {
        var current = try marks.marks(for: documentID)
        let noteIDs = current.annotations.compactMap(\.noteID)
        current.annotations = []
        try marks.replaceMarks(current, for: documentID)
        for id in noteIDs { try notes.delete(id) }
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
}

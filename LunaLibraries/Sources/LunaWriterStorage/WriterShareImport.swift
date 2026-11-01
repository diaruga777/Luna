import Foundation
import LunaCompanionShareCore
import LunaWriterModels

public extension WriterStorageStack {
    /// Stable capture IDs make replay after a process exit safe. Files remain in
    /// the inbox until both the database and the document text have been saved.
    func importSharedCaptures(from inbox: CompanionShareInbox) throws {
        for capture in try inbox.pending() {
            switch capture.kind {
            case .note:
                let id = NoteID(capture.id)
                if try library.note(id) == nil {
                    try library.insert(WriterNote(id: id, text: capture.text, source: .share, createdAt: capture.createdAt))
                }
            case .document:
                let id = DocumentID(capture.id)
                var document = try library.document(id) ?? library.createDocument(in: library.inboxGroupID,
                    title: capture.title.isEmpty ? nil : capture.title, id: id)
                // A revision proves the file and its metadata were committed.
                if document.revision == 0 {
                    let heading = capture.title.isEmpty ? "" : "# \(capture.title)\n\n"
                    try textStore.saveText(heading + capture.text, for: &document)
                }
            default: continue
            }
            try inbox.remove(capture)
        }
    }
}

import Foundation
import LunaWriterModels
import LunaWriterText

/// Splits a sheet into chapters: the palette's "new chapter" command.
public protocol ChapterOrganizing: AnyObject {
    /// Ends `document`'s chapter and opens the next one, holding `text` (what
    /// the editor cut from after the caret). Returns the new chapter's sheet.
    func startNewChapter(after document: WriterDocument, text: String) throws -> WriterDocument
}

/// Keeps chapters as sheets in a `project` group, in manual order.
///
/// The first "new chapter" on a plain sheet makes the project: a group named
/// after the sheet, holding it as chapter one. Every later one adds a sheet
/// right after the current chapter. A chapter whose moved text has no
/// heading of its own gets a "Chapter N" heading, so the sheet has a title
/// the moment it opens.
public final class ChapterOrganizer: ChapterOrganizing {

    public static let projectIcon = "book.closed"

    private let library: WriterLibraryStoring
    private let textStore: DocumentTextStoring

    public init(library: WriterLibraryStoring, textStore: DocumentTextStoring) {
        self.library = library
        self.textStore = textStore
    }

    public func startNewChapter(after document: WriterDocument, text: String) throws -> WriterDocument {
        // The caller's copy can predate the move the last split made; the
        // row is what says which group the sheet is in now.
        let document = try library.document(document.id) ?? document
        let project = try projectGroup(for: document)
        let chapters = try library.documents(in: project.id, sort: .manual)
        let position = (chapters.firstIndex { $0.id == document.id } ?? (chapters.count - 1)) + 1

        var chapter = try library.createDocument(in: project.id, title: nil)
        try library.moveDocument(chapter.id, to: project.id, at: position)

        let body = String(text.drop { $0.isNewline || $0 == " " || $0 == "\t" })
        let hasOwnHeading = TitleDeriver.derive(from: body as NSString)?.isHeading == true
        let heading = hasOwnHeading ? "" : "# " + L10nWriterStorage.chapterTitle(position + 1) + "\n\n"
        try textStore.saveText(heading + body, for: &chapter)
        return chapter
    }

    /// The sheet's project, made around it if it is not in one yet.
    private func projectGroup(for document: WriterDocument) throws -> WriterGroup {
        let groups = try library.groups()
        let current = groups.first { $0.id == document.groupID }
        if let current, current.kind == .project { return current }
        // A project made inside a hand-made folder stays in it; one made in
        // the Inbox goes to the top level, where the Inbox's sheets have no
        // folder to belong to.
        let parent = current.flatMap { $0.kind == .user ? $0.id : nil }
        let name = document.title.isEmpty ? L10nWriterStorage.untitledProjectName : document.title
        let project = try library.createGroup(name: name, icon: Self.projectIcon, parent: parent, kind: .project)
        try library.moveDocument(document.id, to: project.id, at: 0)
        return project
    }
}

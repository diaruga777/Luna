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

extension ChapterOrganizer {
    /// Each collection owns an ordered sequence of chapters. Nested collections
    /// represent parts of a book; existing group IDs and document links stay stable.
    public func createBook(named name: String, parent: GroupID? = nil) throws -> WriterGroup {
        try library.createGroup(name: name, icon: Self.projectIcon, parent: parent, kind: .project)
    }

    public func appendChapter(in group: GroupID, title: String? = nil) throws -> WriterDocument {
        let position = try library.documents(in: group, sort: .manual).count
        var chapter = try library.createDocument(in: group, title: nil)
        let heading = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        try textStore.saveText("# " + ((heading?.isEmpty == false ? heading : nil)
            ?? L10nWriterStorage.chapterTitle(position + 1)) + "\n\n", for: &chapter)
        return chapter
    }

    /// Find the outermost book so navigation includes sibling collections.
    public func book(containing document: WriterDocument) throws -> WriterGroup? {
        let groups = try library.groups()
        var current = groups.first { $0.id == document.groupID }
        var book: WriterGroup?
        var visited = Set<GroupID>()
        while let group = current, visited.insert(group.id).inserted {
            if group.kind == .project { book = group }
            current = groups.first { $0.id == group.parentID }
        }
        return book
    }

    public struct ChapterSection {
        public let group: WriterGroup
        public let depth: Int
        public let chapters: [WriterDocument]
    }

    /// Direct chapters precede subcollections, each in its stored manual order.
    public func contents(of book: GroupID) throws -> [ChapterSection] {
        let groups = try library.groups()
        var result: [ChapterSection] = []
        var visited = Set<GroupID>()
        func visit(_ id: GroupID, depth: Int) throws {
            guard visited.insert(id).inserted, let group = groups.first(where: { $0.id == id }) else { return }
            result.append(ChapterSection(group: group, depth: depth,
                                         chapters: try library.documents(in: id, sort: .manual)))
            for child in groups.filter({ $0.parentID == id && $0.kind.isEditable }).sorted(by: { $0.sortIndex < $1.sortIndex }) {
                try visit(child.id, depth: depth + 1)
            }
        }
        try visit(book, depth: 0)
        return result
    }
}

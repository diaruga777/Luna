import Foundation
import LunaWriterModels


/// The range-bearing data a document carries beside its text. Replaced as a
/// set: an editing session owns both lists while it is open and writes them
/// back together.
public struct DocumentMarks: Equatable, Sendable {
    public var annotations: [Annotation]
    public var authorship: [AuthorshipSpan]

    public init(annotations: [Annotation] = [], authorship: [AuthorshipSpan] = []) {
        self.annotations = annotations
        self.authorship = authorship
    }

    public static let empty = DocumentMarks()
}

/// One kept copy of a document's text, taken before something overwrote it.
public struct DocumentSnapshot: Equatable, Sendable {
    public let documentID: DocumentID
    public let createdAt: Date
    public let text: String

    public init(documentID: DocumentID, createdAt: Date, text: String) {
        self.documentID = documentID
        self.createdAt = createdAt
        self.text = text
    }
}

/// What changed, so a list reloads the part it shows rather than everything.
public enum LibraryChange: Equatable, Sendable {
    case groups
    case documents(in: GroupID)
    case document(DocumentID)
    case notes(DocumentID?)
}

public protocol LibraryChangeObserving: AnyObject {
    func libraryDidChange(_ change: LibraryChange)
}

public protocol WriterLibraryStoring: AnyObject {
    func groups() throws -> [WriterGroup]
    func createGroup(name: String, icon: String, parent: GroupID?) throws -> WriterGroup
    func update(_ group: WriterGroup) throws
    /// Trashes the group's documents, then removes the group and its children.
    func delete(_ id: GroupID) throws
    func moveGroup(_ id: GroupID, to parent: GroupID?, at index: Int) throws

    func documents(in group: GroupID, sort: DocumentSort) throws -> [WriterDocument]
    func documents(matching predicate: FilterPredicate, scope: GroupID?) throws -> [WriterDocument]
    func favorites() throws -> [WriterDocument]
    func recent(days: Int) throws -> [WriterDocument]
    func document(_ id: DocumentID) throws -> WriterDocument?
    func createDocument(in group: GroupID, title: String?) throws -> WriterDocument
    /// Metadata only. Text goes through `DocumentTextStoring`.
    func update(_ document: WriterDocument) throws
    func moveDocument(_ id: DocumentID, to group: GroupID, at index: Int) throws
    func trash(_ id: DocumentID) throws
    func restore(_ id: DocumentID) throws
    func emptyTrash() throws
    func searchDocuments(_ text: String, limit: Int) throws -> [DocumentHit]

    func filters() throws -> [WriterFilter]
    func save(_ filter: WriterFilter) throws
    func deleteFilter(_ id: FilterID) throws

    var inboxGroupID: GroupID { get }
    var trashGroupID: GroupID { get }

    func addObserver(_ observer: LibraryChangeObserving)
    func removeObserver(_ observer: LibraryChangeObserving)
}

public protocol NoteStoring: AnyObject {
    func notes(for document: DocumentID) throws -> [WriterNote]
    func unattachedNotes() throws -> [WriterNote]
    func note(_ id: NoteID) throws -> WriterNote?
    func insert(_ note: WriterNote) throws
    func update(_ note: WriterNote) throws
    func delete(_ id: NoteID) throws
    func attach(_ id: NoteID, to document: DocumentID, attachment: NoteAttachment) throws
    func detach(_ id: NoteID, from document: DocumentID) throws
}

public protocol DocumentMarksStoring: AnyObject {
    func marks(for document: DocumentID) throws -> DocumentMarks
    func replaceMarks(_ marks: DocumentMarks, for document: DocumentID) throws
}

public protocol DocumentSnapshotStoring: AnyObject {
    /// Keeps the newest `DocumentSnapshotLimit.perDocument` copies and drops the rest.
    func recordSnapshot(_ text: String, for document: DocumentID) throws
    func snapshots(for document: DocumentID) throws -> [DocumentSnapshot]
}

public enum DocumentSnapshotLimit {
    public static let perDocument = 20
}

public protocol DocumentTextStoring: AnyObject {
    func loadText(_ document: WriterDocument) throws -> String
    /// Writes the text, re-derives the title and counts, bumps the revision and
    /// moves the file when the title or group changed.
    func saveText(_ text: String, for document: inout WriterDocument) throws
    func deleteText(_ document: WriterDocument) throws
}

/// Holds observers weakly and posts on the main queue after the write commits,
/// so a list reloads on the thread it draws on.
final class LibraryChangeBroadcaster {
    private final class Box {
        weak var observer: LibraryChangeObserving?
        init(_ observer: LibraryChangeObserving) { self.observer = observer }
    }

    private let lock = NSLock()
    private var boxes: [Box] = []

    func add(_ observer: LibraryChangeObserving) {
        lock.lock()
        defer { lock.unlock() }
        boxes.removeAll { $0.observer == nil || $0.observer === observer }
        boxes.append(Box(observer))
    }

    func remove(_ observer: LibraryChangeObserving) {
        lock.lock()
        defer { lock.unlock() }
        boxes.removeAll { $0.observer == nil || $0.observer === observer }
    }

    func post(_ change: LibraryChange) {
        lock.lock()
        boxes.removeAll { $0.observer == nil }
        let observers = boxes.compactMap(\.observer)
        lock.unlock()
        guard !observers.isEmpty else { return }
        DispatchQueue.main.async {
            for observer in observers { observer.libraryDidChange(change) }
        }
    }
}

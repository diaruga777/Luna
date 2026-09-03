import Foundation
import LunaWriterModels
import LunaWriterText

/// Asks whether a sheet is open with edits the library has not seen.
///
/// The reconciler must not adopt a file underneath a writer who is mid
/// sentence, and only the editor knows that. Installed by the app; absent in
/// a background process, where nothing is open.
public protocol OpenDocumentQuerying: AnyObject {
    func hasUnsavedEdits(_ id: DocumentID) -> Bool
}

/// What one scan did.
public struct ReconcileOutcome: Equatable, Sendable {
    public var added: [DocumentID] = []
    public var changed: [DocumentID] = []
    public var trashed: [DocumentID] = []
    public var deferred: [DocumentID] = []

    public init(
        added: [DocumentID] = [], changed: [DocumentID] = [],
        trashed: [DocumentID] = [], deferred: [DocumentID] = []
    ) {
        self.added = added
        self.changed = changed
        self.trashed = trashed
        self.deferred = deferred
    }
}

/// Brings the library back in line with the folder after someone edited it
/// somewhere else — Files, a Mac over iCloud, another editor.
///
/// A file Luna does not know becomes a sheet in the group its folder maps to,
/// and the folder becomes a group when there is none. A file that moved on
/// without us is reloaded and its marks are re-anchored by quote and context,
/// so a comment survives a paragraph moving. A file that is gone trashes its
/// sheet rather than deleting it, because "gone" is also what a sync in
/// progress looks like.
public final class ExternalChangeReconciler: LibraryScanHandling {

    /// How much newer than the row a file must be to count as changed. Covers
    /// the gap between writing a file and stamping the row that describes it.
    public static let changeTolerance: TimeInterval = 0.5

    private let library: WriterLibraryStoring
    private let textStore: FileDocumentTextStore
    private let snapshots: DocumentSnapshotStoring
    private let marksStore: DocumentMarksStoring
    private let documentIndex: DocumentIndexing?

    /// Installed by the app so an open sheet with unsaved edits is left alone.
    public var openDocuments: OpenDocumentQuerying?

    public init(
        library: WriterLibraryStoring, textStore: FileDocumentTextStore,
        snapshots: DocumentSnapshotStoring, marks: DocumentMarksStoring,
        documentIndex: DocumentIndexing? = nil
    ) {
        self.library = library
        self.textStore = textStore
        self.snapshots = snapshots
        self.marksStore = marks
        self.documentIndex = documentIndex
    }

    public func libraryDidScan(_ files: [ExternalFileSnapshot]) {
        _ = try? reconcile(files)
    }

    @discardableResult
    public func reconcile(_ files: [ExternalFileSnapshot]) throws -> ReconcileOutcome {
        var outcome = ReconcileOutcome()
        let documents = try library.documents(matching: FilterPredicate(), scope: nil)
        var byPath: [String: WriterDocument] = [:]
        for document in documents where !document.fileRelativePath.isEmpty {
            byPath[document.fileRelativePath] = document
        }
        var seen = Set<String>()

        for file in files {
            seen.insert(file.relativePath)
            guard let document = byPath[file.relativePath] else {
                outcome.added.append(try adopt(file))
                continue
            }
            guard file.modifiedAt.timeIntervalSince(document.updatedAt) > Self.changeTolerance else {
                continue
            }
            if openDocuments?.hasUnsavedEdits(document.id) == true {
                outcome.deferred.append(document.id)
                continue
            }
            try reload(document, from: file)
            outcome.changed.append(document.id)
        }

        for (path, document) in byPath where !seen.contains(path) {
            try library.trash(document.id)
            try documentIndex?.remove(document.id)
            outcome.trashed.append(document.id)
        }
        return outcome
    }

    // MARK: - Cases

    private func adopt(_ file: ExternalFileSnapshot) throws -> DocumentID {
        let text = (try? String(contentsOf: textStore.url(for: file.relativePath), encoding: .utf8))
            ?? ""
        let group = try groupForFolder(of: file.relativePath)
        let summary = DocumentTextSummary.summarize(text)
        var document = try library.createDocument(in: group, title: summary.title)
        document.fileRelativePath = file.relativePath
        document.snippet = summary.snippet
        document.wordCount = summary.words
        document.characterCount = summary.characters
        document.revision = 1
        try library.update(document)
        try documentIndex?.index(document, body: text)
        return document.id
    }

    private func reload(_ document: WriterDocument, from file: ExternalFileSnapshot) throws {
        let text = (try? String(contentsOf: textStore.url(for: file.relativePath), encoding: .utf8))
            ?? ""
        // The file already holds the new text by the time a scan sees it, so
        // the copy kept here is the text being adopted. A session snapshots
        // what it had before it yields.
        try snapshots.recordSnapshot(text, for: document.id)

        var updated = document
        let summary = DocumentTextSummary.summarize(text)
        updated.title = summary.title
        updated.snippet = summary.snippet
        updated.wordCount = summary.words
        updated.characterCount = summary.characters
        updated.revision += 1
        try library.update(updated)
        try reanchorMarks(of: document.id, in: text)
        try documentIndex?.index(updated, body: text)
    }

    /// Anchors carry their quote and its neighbours, so a mark follows the
    /// text it was made on. One that no longer occurs is dropped rather than
    /// left pointing at whatever moved into its offsets.
    private func reanchorMarks(of id: DocumentID, in text: String) throws {
        var marks = try marksStore.marks(for: id)
        guard !marks.annotations.isEmpty || !marks.authorship.isEmpty else { return }
        marks.annotations = marks.annotations.compactMap { annotation in
            guard let range = TextAnchorResolver.resolve(annotation.anchor, in: text as NSString) else { return nil }
            var updated = annotation
            updated.anchor = TextAnchorResolver.make(range: range, in: text as NSString)
            return updated
        }
        let length = (text as NSString).length
        marks.authorship = marks.authorship.compactMap { span in
            let start = min(span.range.start, length)
            let end = min(span.range.end, length)
            guard end > start else { return nil }
            var updated = span
            updated.range = TextRange(start: start, end: end)
            return updated
        }
        try marksStore.replaceMarks(marks, for: id)
    }

    /// The group whose folder path matches the file's, creating the chain when
    /// the writer made the folder themselves.
    private func groupForFolder(of relativePath: String) throws -> GroupID {
        var components = relativePath.components(separatedBy: "/")
        components.removeLast()
        guard !components.isEmpty else { return library.inboxGroupID }
        var groups = try library.groups()
        if let existing = LibraryFileLayout.group(forFolderPath: components, groups: groups) {
            return existing
        }
        var parent: GroupID?
        for depth in components.indices {
            let path = Array(components[0...depth])
            if let existing = LibraryFileLayout.group(forFolderPath: path, groups: groups) {
                parent = existing
                continue
            }
            let created = try library.createGroup(
                name: components[depth], icon: "folder", parent: parent)
            groups.append(created)
            parent = created.id
        }
        return parent ?? library.inboxGroupID
    }
}

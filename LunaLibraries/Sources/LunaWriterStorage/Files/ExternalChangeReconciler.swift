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
/// progress looks like — and if it comes back, the same row is restored
/// rather than adopted again. A whole folder renamed at once carries its
/// sheets' rows across by matching the untouched bytes, so a group rename in
/// Files does not look like every sheet in it being deleted and re-created.
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

        var byPath: [String: WriterDocument] = [:]
        for document in try library.documents(matching: FilterPredicate(), scope: nil)
        where !document.fileRelativePath.isEmpty {
            byPath[document.fileRelativePath] = document
        }
        var trashedByPath: [String: WriterDocument] = [:]
        for document in try library.documents(in: library.trashGroupID, sort: .modifiedDescending)
        where !document.fileRelativePath.isEmpty {
            trashedByPath[document.fileRelativePath] = document
        }

        var groups = try library.groups()
        var folderPaths = LibraryFileLayout.folderPaths(for: groups)

        var seen = Set<String>()
        var newFiles: [ExternalFileSnapshot] = []
        for file in files {
            seen.insert(file.relativePath)
            guard let document = byPath[file.relativePath] else {
                newFiles.append(file)
                continue
            }
            guard file.modifiedAt.timeIntervalSince(document.updatedAt) > Self.changeTolerance else {
                continue
            }
            if openDocuments?.hasUnsavedEdits(document.id) == true {
                outcome.deferred.append(document.id)
                continue
            }
            if try reload(document, from: file) { outcome.changed.append(document.id) }
        }

        var missing = byPath.values.filter { !seen.contains($0.fileRelativePath) }

        for file in newFiles {
            if let returned = trashedByPath[file.relativePath] {
                if try restoreReturned(returned, from: file) { outcome.changed.append(returned.id) }
                continue
            }
            guard case .text(let text) = textStore.loadText(atRelativePath: file.relativePath) else {
                continue
            }
            if let carried = matchByContent(text, among: missing) {
                missing.removeAll { $0.id == carried.id }
                if try carry(carried, to: file, text: text, groups: &groups, folderPaths: &folderPaths) {
                    outcome.changed.append(carried.id)
                }
                continue
            }
            if let id = try adopt(file, text: text, groups: &groups, folderPaths: &folderPaths) {
                outcome.added.append(id)
            }
        }

        for document in missing {
            try library.trash(document.id)
            try documentIndex?.remove(document.id)
            outcome.trashed.append(document.id)
        }
        return outcome
    }

    // MARK: - Cases

    private func adopt(
        _ file: ExternalFileSnapshot, text: String,
        groups: inout [WriterGroup], folderPaths: inout [GroupID: [String]]
    ) throws -> DocumentID? {
        let group = try groupForFolder(of: file.relativePath, groups: &groups, folderPaths: &folderPaths)
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

    private func reload(_ document: WriterDocument, from file: ExternalFileSnapshot) throws -> Bool {
        guard case .text(let text) = textStore.loadText(atRelativePath: file.relativePath) else {
            return false
        }
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
        return true
    }

    /// The file that vanished under a trashed sheet reappeared at the exact
    /// path it trashed from — an auto-trash never moves the file when there
    /// is none to move, so that path is still the row's identity. Restored,
    /// not re-adopted, so its marks and history survive.
    private func restoreReturned(_ document: WriterDocument, from file: ExternalFileSnapshot) throws -> Bool {
        guard case .text(let text) = textStore.loadText(atRelativePath: file.relativePath) else {
            return false
        }
        var updated = document
        updated.trashedAt = nil
        let summary = DocumentTextSummary.summarize(text)
        updated.title = summary.title
        updated.snippet = summary.snippet
        updated.wordCount = summary.words
        updated.characterCount = summary.characters
        updated.revision += 1
        try library.update(updated)
        try reanchorMarks(of: document.id, in: text)
        try documentIndex?.index(updated, body: text)
        return true
    }

    /// A missing document whose title, snippet and counts exactly match this
    /// text — the fingerprint a folder rename leaves behind, since the bytes
    /// never changed. Ambiguous when more than one candidate shares it:
    /// nothing is guessed, and both sides fall back to trash-and-adopt.
    private func matchByContent(_ text: String, among missing: [WriterDocument]) -> WriterDocument? {
        let summary = DocumentTextSummary.summarize(text)
        let candidates = missing.filter {
            $0.title == summary.title && $0.snippet == summary.snippet
                && $0.wordCount == summary.words && $0.characterCount == summary.characters
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    /// Puts a document whose file moved under a renamed folder back under the
    /// group that now names it, keeping its id, notes and marks.
    private func carry(
        _ document: WriterDocument, to file: ExternalFileSnapshot, text: String,
        groups: inout [WriterGroup], folderPaths: inout [GroupID: [String]]
    ) throws -> Bool {
        let group = try groupForFolder(of: file.relativePath, groups: &groups, folderPaths: &folderPaths)
        var updated = document
        updated.groupID = group
        updated.fileRelativePath = file.relativePath
        updated.trashedAt = nil
        updated.revision += 1
        try library.update(updated)
        try reanchorMarks(of: document.id, in: text)
        try documentIndex?.index(updated, body: text)
        return true
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

    /// The group whose folder path matches the file's, creating the chain
    /// when the writer made the folder themselves. `groups`/`folderPaths` are
    /// shared across one whole scan, so a chain made for an earlier file in
    /// the same folder is not rebuilt — and every group's chain is walked
    /// once, not once per candidate — for the next one.
    private func groupForFolder(
        of relativePath: String, groups: inout [WriterGroup], folderPaths: inout [GroupID: [String]]
    ) throws -> GroupID {
        var components = relativePath.components(separatedBy: "/")
        components.removeLast()
        guard !components.isEmpty else { return library.inboxGroupID }
        if let existing = folderPaths.first(where: { $0.value == components })?.key {
            return existing
        }
        var parent: GroupID?
        for depth in components.indices {
            let path = Array(components[0...depth])
            if let existing = folderPaths.first(where: { $0.value == path })?.key {
                parent = existing
                continue
            }
            let created = try library.createGroup(
                name: components[depth], icon: "folder", parent: parent)
            groups.append(created)
            folderPaths[created.id] = path.map(LibraryFileLayout.sanitize)
            parent = created.id
        }
        return parent ?? library.inboxGroupID
    }
}

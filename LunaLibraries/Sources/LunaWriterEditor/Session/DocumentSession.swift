//
//  DocumentSession.swift
//  LunaWriterEditor
//

import UIKit
import LunaDesignSystem
import LunaWriterModels
import LunaWriterStorage
import LunaWriterText

public protocol DocumentSessionDelegate: AnyObject {
    func documentSessionDidSave(_ session: DocumentSession)
    func documentSession(_ session: DocumentSession, didFailToSave error: Error)
    /// The annotations whose text is gone. They stay in the store, listed.
    func documentSession(_ session: DocumentSession, didReanchorWithOrphans orphans: [Annotation])
    func documentSessionDidReceiveExternalChange(_ session: DocumentSession)
}

extension DocumentSessionDelegate {
    public func documentSession(_ session: DocumentSession, didFailToSave error: Error) {}
}

/// Told when a session's unsaved-changes flag flips, so a registry can
/// update its thread-safe reconciliation guard immediately.
public protocol DocumentSessionObserving: AnyObject {
    func documentSessionUnsavedChangesDidChange(_ session: DocumentSession)
}

/// One open sheet.
///
/// It owns the text, who wrote it and what is marked on it, and it writes all
/// three back: one second after the last keystroke, when the app goes to the
/// background, and when the sheet closes. Closing a sheet that changed also
/// keeps a snapshot of it.
public final class DocumentSession: AnnotationRangeProviding, MarkdownTextStorageObserving {

    public static let autosaveDelay: TimeInterval = 1

    public weak var delegate: DocumentSessionDelegate?

    public private(set) var document: WriterDocument
    public let storage: MarkdownTextStorage
    public let authorship: AuthorshipTracker
    public let settings: WriterSettings

    /// The annotations that still point at text, in document order.
    public private(set) var annotations: [ResolvedAnnotation] = []
    /// The annotations whose text is gone.
    public private(set) var orphanedAnnotations: [Annotation] = []

    public private(set) var hasUnsavedChanges = false {
        didSet {
            if oldValue != hasUnsavedChanges { observer?.documentSessionUnsavedChangesDidChange(self) }
        }
    }
    public weak var observer: DocumentSessionObserving?

    private let textStore: DocumentTextStoring
    private let marksStore: DocumentMarksStoring
    private let snapshots: DocumentSnapshotStoring?
    private var autosaveTimer: Timer?
    private var replacingWholeText = false
    private var storedAnnotations: [AnnotationID: Annotation] = [:]
    private var changedSinceOpen = false
    private var isClosed = false

    /// Where the file and database write actually run — off whatever thread
    /// marks the session dirty. Serial, so a slow write can never race past
    /// a faster one queued after it.
    private let saveQueue = DispatchQueue(label: "com.luna.writer.documentSession.save")
    private var editRevision = 0
    private var submittedRevision = -1
    private var appliedRevision = -1
    // Accessed only on saveQueue, including by a synchronous flush. Keeping
    // the last result here lets a flush finish an in-flight save even while
    // its main-queue completion is still waiting to run.
    private var writtenDocument: WriterDocument
    private var completedWrite: (revision: Int, document: WriterDocument, error: Error?)?

    public init(
        document: WriterDocument,
        textStore: DocumentTextStoring,
        marksStore: DocumentMarksStoring,
        settings: WriterSettings,
        snapshots: DocumentSnapshotStoring? = nil,
        styler: LayoutAttributeStyler? = nil
    ) throws {
        self.document = document
        self.writtenDocument = document
        self.textStore = textStore
        self.marksStore = marksStore
        self.snapshots = snapshots
        self.settings = settings

        let text = try textStore.loadText(document)
        let resolvedStyler = styler ?? LayoutAttributeStyler(
            metrics: EditorMetrics(settings: settings),
            font: ReaderFont(rawValue: settings.fontIdentifier ?? "") ?? .system)
        storage = MarkdownTextStorage(text: text, styler: resolvedStyler)

        let marks = (try? marksStore.marks(for: document.id)) ?? .empty
        authorship = AuthorshipTracker(spans: marks.authorship)
        reanchor(marks.annotations)
        storage.addObserver(self)
    }

    deinit { autosaveTimer?.invalidate() }

    // MARK: - Text

    public var text: String { storage.string }

    // Track actual character mutations, including undo, dictation and marked
    // text. UITextView selection/change callbacks are not ordered edit events.
    public func markdownTextStorage(_ storage: MarkdownTextStorage, didReplace edit: NSRange, replacementLength: Int) {
        guard !replacingWholeText, !isClosed else { return }
        authorship.textDidChange(edit: edit, replacementLength: replacementLength, typedBy: .author)
        shiftAnnotations(edit: edit, replacementLength: replacementLength)
        markDirty()
    }

    public func markdownTextStorage(_ storage: MarkdownTextStorage, didRescan range: NSRange) {}

    public func markAsOwn(_ range: NSRange) {
        authorship.markAsOwn(range)
        markDirty()
    }

    /// Text arrived from a paste or an assistant, already in the storage.
    public func recordInsertion(_ range: NSRange, source: AuthorshipSpan.Source) {
        authorship.record(range: range, source: source)
        markDirty()
    }

    private func markDirty() {
        editRevision &+= 1
        hasUnsavedChanges = true
        changedSinceOpen = true
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        autosaveTimer?.invalidate()
        let timer = Timer(timeInterval: Self.autosaveDelay, repeats: false) { [weak self] _ in
            self?.save()
        }
        RunLoop.main.add(timer, forMode: .common)
        autosaveTimer = timer
    }

    // MARK: - Annotations

    public func resolvedAnnotations(in range: NSRange) -> [ResolvedAnnotation] {
        annotations.filter { NSIntersectionRange($0.range, range).length > 0 }
    }

    public func add(_ annotation: Annotation) {
        storedAnnotations[annotation.id] = annotation
        if let range = TextAnchorResolver.resolve(annotation.anchor, in: storage.nsText) {
            annotations.append(ResolvedAnnotation(id: annotation.id, range: range, kind: annotation.kind))
            annotations.sort { $0.range.location < $1.range.location }
        } else {
            orphanedAnnotations.append(annotation)
        }
        markDirty()
    }

    /// Every stored mark, resolved or orphaned, as the next save writes it.
    public var allStoredAnnotations: [Annotation] { Array(storedAnnotations.values) }

    /// Replaces the stored mark with `annotation`'s id.
    public func updateAnnotation(_ annotation: Annotation) {
        guard storedAnnotations[annotation.id] != nil else { return }
        removeAnnotation(annotation.id)
        add(annotation)
    }

    public func removeAnnotation(_ id: AnnotationID) {
        storedAnnotations[id] = nil
        annotations.removeAll { $0.id == id }
        orphanedAnnotations.removeAll { $0.id == id }
        markDirty()
    }

    /// Puts every annotation back onto the text as it is now, and lists the
    /// ones whose words are gone.
    private func reanchor(_ marks: [Annotation]) {
        storedAnnotations = Dictionary(uniqueKeysWithValues: marks.map { ($0.id, $0) })
        var resolved: [ResolvedAnnotation] = []
        var orphans: [Annotation] = []
        let text = storage.nsText
        for annotation in marks {
            if let range = TextAnchorResolver.resolve(annotation.anchor, in: text) {
                resolved.append(ResolvedAnnotation(id: annotation.id, range: range, kind: annotation.kind))
            } else {
                orphans.append(annotation)
            }
        }
        annotations = resolved.sorted { $0.range.location < $1.range.location }
        orphanedAnnotations = orphans
        if !orphans.isEmpty {
            delegate?.documentSession(self, didReanchorWithOrphans: orphans)
        }
    }

    /// Moves the marks with the text under them. One an edit collapses to
    /// nothing moves to `orphanedAnnotations` — kept, the same as one
    /// orphaned on load — instead of silently disappearing from what the
    /// next save writes out.
    private func shiftAnnotations(edit: NSRange, replacementLength: Int) {
        guard !annotations.isEmpty else { return }
        let start = edit.location
        let end = NSMaxRange(edit)
        let delta = replacementLength - edit.length
        var out: [ResolvedAnnotation] = []
        var newlyOrphaned: [Annotation] = []
        for annotation in annotations {
            let low = shift(annotation.range.location, start: start, end: end, delta: delta)
            let high = shift(NSMaxRange(annotation.range), start: start, end: end, delta: delta)
            if high > low {
                out.append(ResolvedAnnotation(
                    id: annotation.id, range: NSRange(location: low, length: high - low), kind: annotation.kind))
            } else if let stored = storedAnnotations[annotation.id] {
                newlyOrphaned.append(stored)
            }
        }
        annotations = out
        guard !newlyOrphaned.isEmpty else { return }
        orphanedAnnotations.append(contentsOf: newlyOrphaned)
        delegate?.documentSession(self, didReanchorWithOrphans: newlyOrphaned)
    }

    private func shift(_ offset: Int, start: Int, end: Int, delta: Int) -> Int {
        if offset <= start { return offset }
        if offset >= end { return offset + delta }
        return start
    }

    // MARK: - Saving

    public func save() {
        performSave(waitForCompletion: false)
    }

    @discardableResult
    public func saveNow() -> Bool {
        performSave(waitForCompletion: true)
    }

    @discardableResult
    private func performSave(waitForCompletion: Bool) -> Bool {
        guard hasUnsavedChanges, !isClosed else { return !hasUnsavedChanges }
        let revision = editRevision
        guard waitForCompletion || submittedRevision != revision else { return true }
        submittedRevision = revision
        let text = storage.string
        let marks = DocumentMarks(annotations: currentAnnotations(), authorship: authorship.spans)
        autosaveTimer?.invalidate()

        let write = { [self] in
            if let completedWrite, completedWrite.revision == revision, completedWrite.error == nil {
                return completedWrite
            }
            var error: Error?
            do {
                try textStore.saveText(text, for: &writtenDocument)
                try marksStore.replaceMarks(marks, for: writtenDocument.id)
            } catch let failure {
                error = failure
            }
            let result = (revision: revision, document: writtenDocument, error: error)
            completedWrite = result
            return result
        }
        if waitForCompletion {
            let result = saveQueue.sync(execute: write)
            applyWriteResult(result)
            return result.error == nil
        }
        saveQueue.async { [self] in
            let result = write()
            DispatchQueue.main.async { [self] in applyWriteResult(result) }
        }
        return true
    }

    private func applyWriteResult(_ result: (revision: Int, document: WriterDocument, error: Error?)) {
        guard result.revision > appliedRevision else { return }
        if let error = result.error {
            // A newer write/flush may already have saved these changes.
            guard result.revision == editRevision else { return }
            submittedRevision = -1
            scheduleAutosave()
            delegate?.documentSession(self, didFailToSave: error)
            return
        }
        appliedRevision = result.revision
        document = result.document
        hasUnsavedChanges = result.revision != editRevision
        delegate?.documentSessionDidSave(self)
    }

    /// The stored annotations with their anchors made again from where they
    /// sit now, so a later load finds them after the text moved.
    private func currentAnnotations() -> [Annotation] {
        let text = storage.nsText
        var out: [Annotation] = []
        for resolved in annotations {
            guard var annotation = storedAnnotations[resolved.id] else { continue }
            annotation.anchor = TextAnchorResolver.make(range: resolved.range, in: text)
            out.append(annotation)
        }
        out.append(contentsOf: orphanedAnnotations)
        return out
    }

    public func applicationDidEnterBackground() {
        saveNow()
    }

    /// Saves, keeps a copy of a sheet that changed, and stops autosaving.
    public func close() {
        guard !isClosed else { return }
        saveNow()
        if changedSinceOpen {
            try? snapshots?.recordSnapshot(storage.string, for: document.id)
        }
        autosaveTimer?.invalidate()
        isClosed = true
    }

    // MARK: - External change

    /// A library notification may describe a metadata edit, our own save,
    /// or a new file revision from the reconciler. File reads stay off main;
    /// edits made while the read runs take precedence over that read.
    public func refreshDocument(_ latest: WriterDocument) {
        guard latest.id == document.id, !isClosed, !hasUnsavedChanges,
              latest.trashedAt == nil else { return }
        guard latest.revision > document.revision else {
            if latest.revision == document.revision { document = latest }
            return
        }
        let revision = editRevision
        let textStore = self.textStore
        saveQueue.async { [weak self] in
            guard let text = try? textStore.loadText(latest) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isClosed, !self.hasUnsavedChanges,
                      self.editRevision == revision,
                      latest.revision > self.document.revision else { return }
                self.document = latest
                self.externalChangeArrived(text: text)
            }
        }
    }

    /// The file changed under the sheet. The text is replaced and every mark
    /// is put back onto it. Authorship spans are plain ranges with no text
    /// anchor of their own to re-resolve — unlike an annotation, there is no
    /// reliable way to say which stretch of the NEW text a span was about,
    /// so they are dropped rather than left pointing at the wrong words.
    public func externalChangeArrived(text: String) {
        replacingWholeText = true
        storage.setText(text)
        replacingWholeText = false
        authorship.reset(to: [])
        reanchor(Array(storedAnnotations.values))
        hasUnsavedChanges = false
        autosaveTimer?.invalidate()
        delegate?.documentSessionDidReceiveExternalChange(self)
    }

    /// Replaces the whole document text as one programmatic edit, resetting
    /// authorship and undo the same way an external change does. Used by a
    /// snapshot restore — the writer chose this, unlike a file changing
    /// under them, so it keeps a snapshot of what was current before the
    /// swap.
    public func replaceWholeText(_ text: String) {
        guard text != storage.string else { return }
        try? snapshots?.recordSnapshot(storage.string, for: document.id)
        replacingWholeText = true
        storage.setText(text)
        replacingWholeText = false
        authorship.reset(to: [])
        reanchor(Array(storedAnnotations.values))
        markDirty()
        delegate?.documentSessionDidReceiveExternalChange(self)
    }
}

// MARK: - WriterTextViewDataSource

extension DocumentSession: WriterTextViewDataSource {

    public var documentLength: Int { storage.length }

    public func writerTextView(
        _ textView: WriterTextView, selectionTouchesForeignAuthorship range: NSRange
    ) -> Bool {
        authorship.containsForeignAuthorship(in: range, documentLength: storage.length)
    }
}

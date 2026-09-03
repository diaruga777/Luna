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
    /// The annotations whose text is gone. They stay in the store, listed.
    func documentSession(_ session: DocumentSession, didReanchorWithOrphans orphans: [Annotation])
    func documentSessionDidReceiveExternalChange(_ session: DocumentSession)
}

/// One open sheet.
///
/// It owns the text, who wrote it and what is marked on it, and it writes all
/// three back: one second after the last keystroke, when the app goes to the
/// background, and when the sheet closes. Closing a sheet that changed also
/// keeps a snapshot of it.
public final class DocumentSession: AnnotationRangeProviding, AutosaveScheduled {

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

    public private(set) var hasUnsavedChanges = false

    private let textStore: DocumentTextStoring
    private let marksStore: DocumentMarksStoring
    private let snapshots: DocumentSnapshotStoring?
    private let scheduler: AutosaveScheduling
    private let autosaveDelay: TimeInterval
    private var storedAnnotations: [AnnotationID: Annotation] = [:]
    private var changedSinceOpen = false
    private var isClosed = false

    /// Where the file and database write actually run — off whatever thread
    /// marks the session dirty. Serial, so a slow write can never race past
    /// a faster one queued after it.
    private let saveQueue = DispatchQueue(label: "com.luna.writer.documentSession.save")
    /// Bumped by every write this session starts; a write only applies its
    /// result if its own number is still the newest one to have landed.
    private var writeRevision = 0
    private var lastWrittenRevision = 0

    public init(
        document: WriterDocument,
        textStore: DocumentTextStoring,
        marksStore: DocumentMarksStoring,
        settings: WriterSettings,
        snapshots: DocumentSnapshotStoring? = nil,
        styler: LayoutAttributeStyler? = nil,
        scheduler: AutosaveScheduling = TimerAutosaveScheduler(),
        autosaveDelay: TimeInterval = DocumentSession.autosaveDelay
    ) throws {
        self.document = document
        self.textStore = textStore
        self.marksStore = marksStore
        self.snapshots = snapshots
        self.settings = settings
        self.scheduler = scheduler
        self.autosaveDelay = autosaveDelay

        let text = try textStore.loadText(document)
        let resolvedStyler = styler ?? LayoutAttributeStyler(
            metrics: EditorMetrics(settings: settings),
            font: ReaderFont(rawValue: settings.fontIdentifier ?? "") ?? .system)
        storage = MarkdownTextStorage(text: text, styler: resolvedStyler)

        let marks = (try? marksStore.marks(for: document.id)) ?? .empty
        authorship = AuthorshipTracker(spans: marks.authorship)
        reanchor(marks.annotations)
    }

    // MARK: - Text

    public var text: String { storage.string }

    /// One edit made in the text view.
    public func textDidChange(
        edit: NSRange, replacementLength: Int, typedBy source: AuthorshipSpan.Source?
    ) {
        authorship.textDidChange(edit: edit, replacementLength: replacementLength, typedBy: source)
        shiftAnnotations(edit: edit, replacementLength: replacementLength)
        markDirty()
    }

    /// Text arrived from a paste or an assistant, already in the storage.
    public func recordInsertion(_ range: NSRange, source: AuthorshipSpan.Source) {
        authorship.record(range: range, source: source)
        markDirty()
    }

    private func markDirty() {
        hasUnsavedChanges = true
        changedSinceOpen = true
        scheduler.schedule(after: autosaveDelay, for: self)
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

    public func autosaveDeadlineReached() {
        save()
    }

    /// Writes what changed since the last save. The snapshot — the text,
    /// the marks — is taken here, on whatever thread called this; the file
    /// and database I/O run on `saveQueue`, off it.
    public func save() {
        performSave(waitForCompletion: false)
    }

    /// Writes synchronously: waits for this write, and for anything already
    /// queued ahead of it, to land before returning. `flushPendingSave()`
    /// and a background flush both need the write actually DONE before
    /// they hand control back — an async fire-and-forget would let the
    /// scene suspend, or the sheet close, out from under it.
    @discardableResult
    public func saveNow() -> Bool {
        performSave(waitForCompletion: true)
    }

    @discardableResult
    private func performSave(waitForCompletion: Bool) -> Bool {
        guard hasUnsavedChanges, !isClosed else {
            if waitForCompletion { saveQueue.sync {} }
            return true
        }
        writeRevision &+= 1
        let revision = writeRevision
        let text = storage.string
        let marks = DocumentMarks(annotations: currentAnnotations(), authorship: authorship.spans)
        hasUnsavedChanges = false
        scheduler.cancel()

        if waitForCompletion {
            var updated = document
            var succeeded = false
            saveQueue.sync {
                do {
                    try self.textStore.saveText(text, for: &updated)
                    try self.marksStore.replaceMarks(marks, for: updated.id)
                    succeeded = true
                } catch {
                    succeeded = false
                }
            }
            applyWriteResult(revision: revision, updated: updated, succeeded: succeeded)
            return succeeded
        } else {
            let textStore = self.textStore
            let marksStore = self.marksStore
            var updated = document
            saveQueue.async { [weak self] in
                var succeeded = true
                do {
                    try textStore.saveText(text, for: &updated)
                    try marksStore.replaceMarks(marks, for: updated.id)
                } catch {
                    succeeded = false
                }
                DispatchQueue.main.async {
                    self?.applyWriteResult(revision: revision, updated: updated, succeeded: succeeded)
                }
            }
            return true
        }
    }

    /// A revision guard: a write that started before a later one already
    /// landed must never overwrite that newer result. A failed write leaves
    /// `hasUnsavedChanges` set so the next edit — or the next background
    /// flush — retries it.
    private func applyWriteResult(revision: Int, updated: WriterDocument, succeeded: Bool) {
        guard succeeded else {
            hasUnsavedChanges = true
            return
        }
        guard revision >= lastWrittenRevision else { return }
        lastWrittenRevision = revision
        document = updated
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
        scheduler.cancel()
        isClosed = true
    }

    // MARK: - External change

    /// The file changed under the sheet. The text is replaced and every mark
    /// is put back onto it. Authorship spans are plain ranges with no text
    /// anchor of their own to re-resolve — unlike an annotation, there is no
    /// reliable way to say which stretch of the NEW text a span was about,
    /// so they are dropped rather than left pointing at the wrong words.
    public func externalChangeArrived(text: String) {
        storage.setText(text)
        authorship.reset(to: [])
        reanchor(Array(storedAnnotations.values))
        hasUnsavedChanges = false
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
        storage.setText(text)
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

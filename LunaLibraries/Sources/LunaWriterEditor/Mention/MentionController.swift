//
//  MentionController.swift
//  LunaWriterEditor
//

import UIKit
import LunaWriterModels
import LunaWriterStorage
import LunaWriterText

/// Where the "@" overlay is in its short life.
public enum MentionState: Equatable {
    case idle
    /// "@" was typed and nothing follows it yet.
    case armed(marker: Int)
    /// Characters after the "@" are the query.
    case querying(marker: Int, query: String)

    public var marker: Int? {
        switch self {
        case .idle: return nil
        case .armed(let marker): return marker
        case .querying(let marker, _): return marker
        }
    }

    public var query: String {
        switch self {
        case .idle, .armed: return ""
        case .querying(_, let query): return query
        }
    }

    public var isActive: Bool { marker != nil }
}

public protocol MentionControllerDelegate: AnyObject {
    func mentionController(_ controller: MentionController, didChange state: MentionState)
    func mentionController(_ controller: MentionController, didUpdate results: [NoteHit], query: String)
    /// Show the note over the text. The "@" and the query stay until Close.
    func mentionController(_ controller: MentionController, didRequestPeek note: WriterNote)
    /// A note was made from the query; fly it toward the notes button.
    func mentionController(_ controller: MentionController, didCreate note: WriterNote, from markerRect: CGRect)
    func mentionControllerDidEnd(_ controller: MentionController)
}

/// The "@" system: a lookup and a capture, never an insert.
///
/// The "@" is typed into the sheet like any other character and the query
/// after it is ordinary text. Picking a note opens it over the page (Q5,
/// peek only); the last row makes a note out of what was typed. Whatever the
/// writer does, the words they typed stay in the sheet.
public final class MentionController {

    public static let maximumQueryWords = 6
    public static let resultLimit = 6
    public static let defaultDebounce: TimeInterval = 0.12

    public weak var delegate: MentionControllerDelegate?
    public weak var textView: WriterTextView?

    private let noteIndex: NoteIndexing
    private let noteStore: NoteStoring
    private let documentID: DocumentID
    private let debounce: TimeInterval
    private let searchQueue: DispatchQueue

    public private(set) var state: MentionState = .idle {
        didSet {
            guard state != oldValue else { return }
            delegate?.mentionController(self, didChange: state)
            // The one place a transition to idle is reported: `end()` used
            // to also call this explicitly, which meant every dismissal
            // told the delegate twice.
            if state == .idle {
                delegate?.mentionControllerDidEnd(self)
            }
        }
    }

    public private(set) var results: [NoteHit] = []

    /// The row Return commits. `results.count` is the "New note" row.
    public private(set) var highlightedIndex: Int = 0

    /// True while a note is shown over the text. The query stays put.
    public private(set) var isPeeking = false

    private var searchTimer: Timer?
    private var searchGeneration = 0
    private var isApplyingOwnEdit = false

    public init(
        noteIndex: NoteIndexing,
        noteStore: NoteStoring,
        documentID: DocumentID,
        debounce: TimeInterval = defaultDebounce,
        searchQueue: DispatchQueue = DispatchQueue(label: "com.luna.writer.mention", qos: .userInitiated)
    ) {
        self.noteIndex = noteIndex
        self.noteStore = noteStore
        self.documentID = documentID
        self.debounce = debounce
        self.searchQueue = searchQueue
    }

    deinit { searchTimer?.invalidate() }

    // MARK: - Text view hooks

    /// Arms on an "@" typed at a word boundary with nothing selected. The "@"
    /// itself is always inserted.
    public func textView(
        _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
    ) -> Bool {
        guard !isApplyingOwnEdit else { return true }
        if text == "@", range.length == 0, isWordBoundary(before: range.location, in: textView) {
            results = []
            highlightedIndex = 0
            isPeeking = false
            state = .armed(marker: range.location)
            return true
        }
        if state.isActive, text.contains("\n") { end() }
        return true
    }

    public func textViewDidChange(_ textView: UITextView) {
        refresh(textView)
    }

    public func textViewDidChangeSelection(_ textView: UITextView) {
        refresh(textView)
    }

    private func refresh(_ textView: UITextView) {
        guard !isApplyingOwnEdit, !isPeeking, let marker = state.marker else { return }
        let text = textView.text as NSString
        guard marker < text.length, text.character(at: marker) == unichar(64) else {
            end()
            return
        }
        let selection = textView.selectedRange
        guard selection.length == 0, selection.location > marker,
              selection.location <= text.length
        else {
            end()
            return
        }
        let queryRange = NSRange(location: marker + 1, length: selection.location - marker - 1)
        let query = text.substring(with: queryRange)
        guard isAcceptable(query) else {
            end()
            return
        }
        state = query.isEmpty ? .armed(marker: marker) : .querying(marker: marker, query: query)
        scheduleSearch(for: query)
    }

    /// A query stops being one when it runs onto another line, past six words,
    /// or into the double space that ends a sentence.
    private func isAcceptable(_ query: String) -> Bool {
        guard !query.contains("\n"), !query.contains("\r") else { return false }
        guard !query.hasSuffix("  ") else { return false }
        let words = query.split(whereSeparator: { $0 == " " || $0 == "\t" })
        return words.count <= Self.maximumQueryWords
    }

    private func isWordBoundary(before location: Int, in textView: UITextView) -> Bool {
        guard location > 0 else { return true }
        let text = textView.text as NSString
        guard location <= text.length else { return false }
        let scalar = text.character(at: location - 1)
        guard let unicode = Unicode.Scalar(scalar) else { return true }
        return CharacterSet.whitespacesAndNewlines.contains(unicode)
            || CharacterSet.punctuationCharacters.contains(unicode)
    }

    // MARK: - Searching

    private func scheduleSearch(for query: String) {
        searchTimer?.invalidate()
        guard !query.isEmpty else {
            deliver([], for: query)
            return
        }
        searchGeneration &+= 1
        let generation = searchGeneration
        searchTimer = Timer.scheduledTimer(withTimeInterval: debounce, repeats: false) { [weak self] _ in
            self?.runSearch(query, generation: generation)
        }
    }

    private func runSearch(_ query: String, generation: Int) {
        searchQueue.async { [weak self] in
            guard let self else { return }
            let hits = self.hits(for: query)
            DispatchQueue.main.async {
                guard generation == self.searchGeneration, self.state.query == query else { return }
                self.deliver(hits, for: query)
            }
        }
    }

    /// The sheet's own notes first, then the rest of the library under them.
    private func hits(for query: String) -> [NoteHit] {
        let local = (try? noteIndex.search(NoteQuery(
            text: query, scope: .document(documentID),
            prefixMatchesLastToken: true, limit: Self.resultLimit))) ?? []
        let seen = Set(local.map { $0.noteID })
        let everywhere = (try? noteIndex.search(NoteQuery(
            text: query, scope: .all,
            prefixMatchesLastToken: true, limit: Self.resultLimit))) ?? []
        return Array((local + everywhere.filter { !seen.contains($0.noteID) }).prefix(Self.resultLimit))
    }

    private func deliver(_ hits: [NoteHit], for query: String) {
        results = hits
        highlightedIndex = min(highlightedIndex, hits.count)
        delegate?.mentionController(self, didUpdate: hits, query: query)
    }

    // MARK: - Rows

    /// The number of rows the overlay shows, the "New note" row included.
    public var rowCount: Int { results.count + 1 }

    public func moveHighlight(by delta: Int) {
        guard state.isActive, rowCount > 0 else { return }
        let next = highlightedIndex + delta
        highlightedIndex = min(max(0, next), rowCount - 1)
    }

    public func highlightRow(_ index: Int) {
        guard index >= 0, index < rowCount else { return }
        highlightedIndex = index
    }

    /// Return: peeks the highlighted note, or makes one from the query.
    public func commitHighlighted() {
        guard state.isActive else { return }
        if highlightedIndex < results.count {
            peek(results[highlightedIndex].noteID)
        } else {
            createNoteFromQuery()
        }
    }

    // MARK: - Actions

    /// Opens the note over the text. Nothing is inserted and the query stays.
    public func peek(_ noteID: NoteID) {
        guard let note = try? noteStore.note(noteID) else { return }
        isPeeking = true
        searchTimer?.invalidate()
        delegate?.mentionController(self, didRequestPeek: note)
    }

    /// Closes a peek: the "@" and the query go, and the caret returns to
    /// where the "@" was.
    ///
    /// `refresh(_:)` ignores every edit while a peek is up, so the span it
    /// cached could be stale by the time it closes — an edit elsewhere in
    /// the document may have moved or erased the "@". The span is checked
    /// fresh here before anything is removed.
    public func closePeek() {
        guard isPeeking else { return }
        isPeeking = false
        guard let textView, recomputedSpanAfterPeek(textView) else {
            end()
            return
        }
        removeQueryText()
        end()
    }

    /// Re-reads the query from the live text. Returns false when the "@" no
    /// longer marks a live query, in which case nothing should be removed.
    private func recomputedSpanAfterPeek(_ textView: UITextView) -> Bool {
        guard let marker = state.marker else { return false }
        let text = textView.text as NSString
        guard marker < text.length, text.character(at: marker) == unichar(64) else { return false }
        let selection = textView.selectedRange
        guard selection.length == 0, selection.location > marker, selection.location <= text.length else {
            return false
        }
        let queryRange = NSRange(location: marker + 1, length: selection.location - marker - 1)
        state = .querying(marker: marker, query: text.substring(with: queryRange))
        return true
    }

    /// Makes a note out of what was typed, anchored where the "@" was. The
    /// store write runs on `searchQueue`, off the keystroke's own thread.
    public func createNoteFromQuery() {
        let text = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let marker = state.marker, !text.isEmpty else {
            end()
            return
        }
        let anchor = textView.map { view -> TextAnchor in
            TextAnchorResolver.make(range: NSRange(location: marker, length: 0), in: view.text as NSString)
        }
        let note = WriterNote(
            documentIDs: [documentID], text: text, source: .mention, anchor: anchor)
        let noteStore = self.noteStore
        let noteIndex = self.noteIndex
        let documentID = self.documentID
        searchQueue.async { [weak self] in
            var succeeded = true
            do {
                try noteStore.insert(note)
                try noteStore.attach(note.id, to: documentID, attachment: .mention)
                try? noteIndex.index(note)
            } catch {
                succeeded = false
            }
            DispatchQueue.main.async {
                self?.finishCreatingNote(note, forMarker: marker, succeeded: succeeded)
            }
        }
    }

    /// `marker` pins this to the query the write was about. If the writer
    /// moved on before the write finished — a different mention, or none —
    /// the note is still saved, but there is no query text left to remove
    /// and no marker left to fly the note in from.
    private func finishCreatingNote(_ note: WriterNote, forMarker marker: Int, succeeded: Bool) {
        guard succeeded else {
            if state.marker == marker { end() }
            return
        }
        guard state.marker == marker else { return }
        let rect = markerRect()
        removeQueryText()
        delegate?.mentionController(self, didCreate: note, from: rect)
        end()
    }

    /// Esc, a tap outside, or a rule that cancelled the query. The typed text
    /// stays exactly as it is.
    public func dismiss() {
        isPeeking = false
        end()
    }

    private func end() {
        searchTimer?.invalidate()
        searchTimer = nil
        results = []
        highlightedIndex = 0
        state = .idle
    }

    // MARK: - Editing the sheet

    /// Where the "@" sits on screen, for the overlay and the fly-in.
    public func markerRect() -> CGRect {
        guard let textView, let marker = state.marker,
              let position = textView.position(from: textView.beginningOfDocument, offset: marker)
        else { return .zero }
        return textView.caretRect(for: position)
    }

    private func removeQueryText() {
        guard let textView, let marker = state.marker else { return }
        let length = 1 + (state.query as NSString).length
        let end = min(marker + length, (textView.text as NSString).length)
        guard end > marker else { return }
        isApplyingOwnEdit = true
        textView.replaceText(in: NSRange(location: marker, length: end - marker), with: "")
        textView.selectedRange = NSRange(location: marker, length: 0)
        isApplyingOwnEdit = false
    }
}

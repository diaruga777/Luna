//
//  CommandPaletteController.swift
//  LunaWriterEditor
//

import UIKit
import LunaModels
import LunaWriterModels
import LunaWriterStorage
import LunaWriterText

/// Where the palette is in its short life.
public enum PaletteState: Equatable {
    case idle
    /// The palette opened and nothing has been typed into it yet.
    case armed(marker: Int)
    /// The text typed after the marker is the query.
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

/// What tapping a row does.
public enum PaletteAction: Equatable {
    case peekNote(NoteID)
    case createNote
    /// Replaces the typed query with `text`.
    case insertText(String)
    case startChapter
    /// A message row: nothing happens.
    case none
}

/// One row of the palette.
public struct PaletteRow: Equatable {
    public var title: String
    public var detail: String?
    public var symbolName: String
    public var action: PaletteAction
    /// A symbol is displayed as a tile; its name remains available to VoiceOver.
    public var symbolCharacter: String?
    /// How well the row matches the query, `0...1`. A row at or above
    /// `CommandPaletteController.returnThreshold` in first place is what
    /// Return runs.
    public var score: Double

    public init(title: String, detail: String? = nil, symbolName: String, action: PaletteAction, score: Double = 0, symbolCharacter: String? = nil) {
        self.title = title
        self.detail = detail
        self.symbolName = symbolName
        self.action = action
        self.score = score
        self.symbolCharacter = symbolCharacter
    }
}

extension PaletteRow {
    /// Symbols share a row at the strongest symbol's position. Keep the
    /// underlying ranked indices so taps and Return still resolve identically.
    static func displayGroups(in rows: [PaletteRow]) -> [[Int]] {
        let symbols = rows.indices.filter { rows[$0].symbolCharacter != nil }
        return rows.indices.compactMap { index in
            if rows[index].symbolCharacter == nil { return [index] }
            return index == symbols.first ? symbols : nil
        }
    }
}

public protocol CommandPaletteControllerDelegate: AnyObject {
    func commandPalette(_ controller: CommandPaletteController, didChange state: PaletteState)
    func commandPalette(_ controller: CommandPaletteController, didUpdate rows: [PaletteRow])
    /// Show the note over the text. The marker and the query stay until Close.
    func commandPalette(_ controller: CommandPaletteController, didRequestPeek note: WriterNote)
    /// A note was made from the query; fly it toward the notes button.
    func commandPalette(_ controller: CommandPaletteController, didCreate note: WriterNote, from markerRect: CGRect)
    /// The query is gone and the palette closed; the editor now ends the
    /// chapter at the caret.
    func commandPaletteDidRequestNewChapter(_ controller: CommandPaletteController)
    func commandPaletteDidEnd(_ controller: CommandPaletteController)
}

/// The inline command palette: a note lookup, a note capture, and commands.
///
/// It opens on a fast double space (the second space is swallowed and the
/// query is typed straight into the sheet) or, by setting, on an "@" typed
/// at a word boundary. The query is ordinary text until a row acts on it: a
/// note row peeks (never inserts, Q5), the last row makes a note, a symbol
/// or thesaurus row replaces the query with its word, and "new chapter" hands the caret to
/// the editor. Whatever the writer does, only the query text is ever taken
/// out of the sheet.
public final class CommandPaletteController {

    public static let maximumQueryWords = 6
    public static let resultLimit = 6
    public static let symbolRowLimit = 8
    public static let synonymRowLimit = 8
    public static let defaultDebounce: TimeInterval = 0.12
    /// Two spaces this close together open the palette; slower is a
    /// sentence's double space and stays text.
    public static let doubleSpaceInterval: TimeInterval = 0.3
    /// Drop accidental command and symbol matches from scattered letters.
    static let commandMatchFloor = 0.4
    /// A direct word or prefix match can run on Return. Semantic alternatives
    /// stay below this threshold until the writer chooses one.
    public static let returnThreshold = 0.8

    public weak var delegate: CommandPaletteControllerDelegate?
    public weak var textView: WriterTextView?

    /// What opens the palette. The editor sets it from `WriterSettings`.
    public var trigger: PaletteTrigger = .doubleSpace

    private let noteIndex: NoteIndexing
    private let noteStore: NoteStoring
    private let documentID: DocumentID
    private let thesaurus: WordThesaurus?
    private let symbols: SymbolCatalog
    private let debounce: TimeInterval
    private let searchQueue: DispatchQueue
    private let now: () -> TimeInterval

    public private(set) var state: PaletteState = .idle {
        didSet {
            guard state != oldValue else { return }
            delegate?.commandPalette(self, didChange: state)
            // The one place a transition to idle is reported.
            if state == .idle {
                delegate?.commandPaletteDidEnd(self)
            }
        }
    }

    /// How many characters the marker itself takes in the text: one for an
    /// "@", none for a double space.
    public private(set) var markerLength = 0

    /// The note hits behind the note rows.
    public private(set) var results: [NoteHit] = []
    public private(set) var rows: [PaletteRow] = []

    /// The row Return commits: the first row when its match is strong, or
    /// the one the arrow keys or a tap chose. nil means Return types a
    /// newline and closes the palette.
    public private(set) var highlightedIndex: Int?
    /// True once the arrows or a tap chose a row, so a later delivery for
    /// the same query keeps that choice instead of jumping back to the top.
    private var highlightPinned = false
    private var pinnedQuery = ""

    /// True while a note is shown over the text. The query stays put.
    public private(set) var isPeeking = false

    private var searchTimer: Timer?
    private var searchGeneration = 0
    private var isApplyingOwnEdit = false
    /// The single space typed last, for the double-space trigger.
    private var lastSpace: (location: Int, at: TimeInterval)?

    public init(
        noteIndex: NoteIndexing,
        noteStore: NoteStoring,
        documentID: DocumentID,
        thesaurus: WordThesaurus? = nil,
        symbols: SymbolCatalog = .shared,
        debounce: TimeInterval = defaultDebounce,
        searchQueue: DispatchQueue = DispatchQueue(label: "com.luna.writer.palette", qos: .userInitiated),
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.noteIndex = noteIndex
        self.noteStore = noteStore
        self.documentID = documentID
        self.thesaurus = thesaurus
        self.symbols = symbols
        self.debounce = debounce
        self.searchQueue = searchQueue
        self.now = now
    }

    deinit { searchTimer?.invalidate() }

    // MARK: - Text view hooks

    /// Opens the palette on its trigger. An "@" is always inserted; the
    /// second space of a fast double space is not. Backspace on an empty
    /// palette closes it and deletes nothing.
    public func textView(
        _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
    ) -> Bool {
        guard !isApplyingOwnEdit else { return true }
        if state.isActive, !isPeeking, text.isEmpty, state.query.isEmpty, let marker = state.marker,
           range.length == 1, range.location == marker + markerLength - 1 {
            if markerLength == 0 {
                end()
                return false
            }
            // Deleting the "@" itself: the refresh after the edit sees it gone.
            return true
        }
        if state.isActive, text == "\n", range.length == 0, !isPeeking, let index = highlightedIndex,
           index < rows.count {
            perform(rows[index].action)
            return false
        }
        if state.isActive, text.contains("\n") { end() }
        guard state == .idle else { return true }

        switch trigger {
        case .atSign:
            if text == "@", range.length == 0, isWordBoundary(before: range.location, in: textView) {
                arm(marker: range.location, markerLength: 1)
            }
            return true
        case .doubleSpace:
            return handleDoubleSpaceTrigger(textView, range: range, text: text)
        }
    }

    /// A second space typed straight after a first one opens the palette,
    /// after the first space, and is not typed. iOS's own double-space
    /// shortcut arrives as ". " replacing the first space and is refused the
    /// same way. Any other keystroke, or a slow second space, resets the clock.
    private func handleDoubleSpaceTrigger(_ textView: UITextView, range: NSRange, text: String) -> Bool {
        let time = now()
        let previous = lastSpace
        lastSpace = (text == " " && range.length == 0) ? (range.location, time) : nil
        guard let previous, time - previous.at <= Self.doubleSpaceInterval else { return true }
        let content = textView.text as NSString
        let isSecondSpace = text == " " && range.length == 0 && range.location == previous.location + 1
        let isPeriodShortcut = text == ". " && range.length == 1 && range.location == previous.location
        guard isSecondSpace || isPeriodShortcut,
              previous.location < content.length, content.character(at: previous.location) == 0x20
        else { return true }
        arm(marker: previous.location + 1, markerLength: 0)
        return false
    }

    private func arm(marker: Int, markerLength: Int) {
        results = []
        rows = []
        highlightedIndex = nil
        highlightPinned = false
        isPeeking = false
        lastSpace = nil
        self.markerLength = markerLength
        state = .armed(marker: marker)
        deliver(hits: [], for: "")
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
        guard markerIsIntact(marker, in: text) else {
            end()
            return
        }
        let selection = textView.selectedRange
        let queryStart = marker + markerLength
        guard selection.length == 0, selection.location >= queryStart, selection.location <= text.length
        else {
            end()
            return
        }
        let queryRange = NSRange(location: queryStart, length: selection.location - queryStart)
        let query = text.substring(with: queryRange)
        guard isAcceptable(query) else {
            end()
            return
        }
        if highlightPinned, query != pinnedQuery { highlightPinned = false }
        state = query.isEmpty ? .armed(marker: marker) : .querying(marker: marker, query: query)
        scheduleSearch(for: query)
    }

    /// An "@" marker must still be an "@"; a double-space marker must still
    /// follow the space that opened it.
    private func markerIsIntact(_ marker: Int, in text: NSString) -> Bool {
        if markerLength == 1 {
            return marker < text.length && text.character(at: marker) == unichar(64)
        }
        return marker > 0 && marker <= text.length && text.character(at: marker - 1) == 0x20
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
        searchGeneration &+= 1
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            deliver(hits: [], for: query)
            return
        }
        // A new query must not retain a Return action from the previous search.
        if !highlightPinned {
            rows = []
            results = []
            highlightedIndex = nil
            delegate?.commandPalette(self, didUpdate: rows)
        }
        let generation = searchGeneration
        searchTimer = Timer.scheduledTimer(withTimeInterval: debounce, repeats: false) { [weak self] _ in
            self?.runSearch(query, generation: generation)
        }
    }

    private func runSearch(_ query: String, generation: Int) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchQueue.async { [weak self] in
            guard let self else { return }
            let hits = self.hits(for: trimmed)
            let found = self.searchRows(for: trimmed)
            DispatchQueue.main.async {
                guard generation == self.searchGeneration, self.state.query == query else { return }
                self.deliver(hits: hits, for: query, searchRows: found)
            }
        }
    }

    /// Search both scopes; the sheet only breaks ties, never outranks a stronger match.
    private func hits(for query: String) -> [NoteHit] {
        guard !query.isEmpty else { return [] }
        let local = (try? noteIndex.search(NoteQuery(
            text: query, scope: .document(documentID),
            prefixMatchesLastToken: true, limit: Self.resultLimit))) ?? []
        let seen = Set(local.map { $0.noteID })
        let everywhere = (try? noteIndex.search(NoteQuery(
            text: query, scope: .all,
            prefixMatchesLastToken: true, limit: Self.resultLimit))) ?? []
        return (local + everywhere.filter { !seen.contains($0.noteID) })
            .enumerated().sorted {
                let lhs = Self.noteScore($0.element, for: query)
                let rhs = Self.noteScore($1.element, for: query)
                return lhs == rhs ? $0.offset < $1.offset : lhs > rhs
            }.prefix(Self.resultLimit).map(\.element)
    }

    /// Every nonempty query searches every domain. Runs off the main thread.
    private func searchRows(for query: String) -> [PaletteRow] {
        var found = symbols.matches(query, limit: Self.symbolRowLimit)
            .filter { $0.score >= Self.commandMatchFloor }
            .map { symbol, score in
                PaletteRow(
                    title: symbol.name,
                    symbolName: "character", action: .insertText(symbol.character), score: score,
                    symbolCharacter: symbol.character)
            }
        if let thesaurus, thesaurus.isAvailable {
            found.append(contentsOf: thesaurus.matches(for: query, limit: Self.synonymRowLimit).map {
                PaletteRow(title: $0.word, symbolName: "text.book.closed",
                           action: .insertText($0.word), score: $0.score)
            })
        }
        let chapterTitle = L10n.string("WriterEditor_commandNewChapter")
        if let score = FuzzyMatcher.score(query: query, candidate: chapterTitle), score >= Self.commandMatchFloor {
            found.append(PaletteRow(
                title: chapterTitle,
                symbolName: "book.pages", action: .startChapter, score: score))
        }
        return found
    }

    /// Merge every domain by match strength, keeping ties stable. Note capture
    /// stays at the end and is available only for a nonempty query.
    private func deliver(hits: [NoteHit], for query: String, searchRows: [PaletteRow] = []) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        results = trimmed.isEmpty ? [] : hits
        var assembled = trimmed.isEmpty ? [] : searchRows
        assembled.append(contentsOf: results.map { hit in
            PaletteRow(
                title: hit.noteText.isEmpty ? hit.snippet : hit.noteText,
                detail: hit.documentIDs.contains(documentID)
                    ? nil : L10n.string("WriterEditor_paletteNoteFromAnotherSheet"),
                symbolName: "note.text", action: .peekNote(hit.noteID),
                score: Self.noteScore(hit, for: trimmed))
        })
        assembled = assembled.enumerated().sorted {
            $0.element.score == $1.element.score
                ? $0.offset < $1.offset : $0.element.score > $1.element.score
        }.map(\.element)
        // A strip of symbols uses only one of the six visible result rows.
        var usedRows = 0
        var hasSymbols = false
        assembled = assembled.filter { row in
            if row.symbolCharacter != nil, hasSymbols { return true }
            guard usedRows < Self.resultLimit else { return false }
            usedRows += 1
            if row.symbolCharacter != nil { hasSymbols = true }
            return true
        }
        if !trimmed.isEmpty {
            assembled.append(PaletteRow(
                title: L10n.string("WriterEditor_paletteNewNoteNamed", trimmed),
                symbolName: "plus.circle", action: .createNote,
                score: assembled.isEmpty ? 1 : 0))
        }
        rows = assembled
        if highlightPinned, let pinned = highlightedIndex, pinned < rows.count {
            // The writer's own choice stands for this query.
        } else {
            highlightPinned = false
            highlightedIndex = Self.defaultRow(in: rows)
        }
        delegate?.commandPalette(self, didUpdate: rows)
    }

    /// Match note text on the same scale as symbol names and commands,
    /// retaining the index's semantic score when stronger.
    private static func noteScore(_ hit: NoteHit, for query: String) -> Double {
        max(hit.score, FuzzyMatcher.score(
            query: query, candidate: hit.noteText.isEmpty ? hit.snippet : hit.noteText) ?? 0)
    }

    /// The first row, when its match is sure enough for Return to run it.
    static func defaultRow(in rows: [PaletteRow]) -> Int? {
        guard let first = rows.first, first.action != .none, first.score >= returnThreshold else { return nil }
        return 0
    }

    // MARK: - Rows

    public var rowCount: Int { rows.count }

    /// Steps the highlight. With none yet, down lands on the first row and
    /// up on the last.
    public func moveHighlight(by delta: Int) {
        guard state.isActive, rowCount > 0 else { return }
        let order = PaletteRow.displayGroups(in: rows).flatMap { $0 }
        let next: Int
        if let current = highlightedIndex, let position = order.firstIndex(of: current) {
            next = position + delta
        } else {
            next = delta >= 0 ? 0 : order.count - 1
        }
        pin(order[min(max(0, next), order.count - 1)])
    }

    public func highlightRow(_ index: Int) {
        guard index >= 0, index < rowCount else { return }
        pin(index)
    }

    private func pin(_ index: Int) {
        highlightedIndex = index
        highlightPinned = true
        pinnedQuery = state.query
    }

    /// Return: runs the highlighted row. False when no row is highlighted,
    /// so the caller lets Return type its newline.
    @discardableResult
    public func commitHighlighted() -> Bool {
        guard state.isActive, let index = highlightedIndex, index < rows.count else { return false }
        perform(rows[index].action)
        return true
    }

    public func perform(_ action: PaletteAction) {
        guard state.isActive else { return }
        switch action {
        case .peekNote(let id): peek(id)
        case .createNote: createNoteFromQuery()
        case .insertText(let text): replaceQuery(with: text)
        case .startChapter:
            removeQueryText()
            end()
            delegate?.commandPaletteDidRequestNewChapter(self)
        case .none: break
        }
    }

    // MARK: - Actions

    /// Opens the note over the text. Nothing is inserted and the query stays.
    public func peek(_ noteID: NoteID) {
        guard let note = try? noteStore.note(noteID) else { return }
        isPeeking = true
        searchTimer?.invalidate()
        delegate?.commandPalette(self, didRequestPeek: note)
    }

    /// Closes a peek: the marker and the query go, and the caret returns to
    /// where the marker was.
    ///
    /// `refresh(_:)` ignores every edit while a peek is up, so the span it
    /// cached could be stale by the time it closes — an edit elsewhere in
    /// the document may have moved or erased the marker. The span is checked
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

    /// Re-reads the query from the live text. Returns false when the marker
    /// no longer marks a live query, in which case nothing should be removed.
    private func recomputedSpanAfterPeek(_ textView: UITextView) -> Bool {
        guard let marker = state.marker else { return false }
        let text = textView.text as NSString
        guard markerIsIntact(marker, in: text) else { return false }
        let selection = textView.selectedRange
        let queryStart = marker + markerLength
        guard selection.length == 0, selection.location >= queryStart, selection.location <= text.length else {
            return false
        }
        let queryRange = NSRange(location: queryStart, length: selection.location - queryStart)
        state = .querying(marker: marker, query: text.substring(with: queryRange))
        return true
    }

    /// Makes a note out of what was typed, anchored where the marker was. The
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
    /// moved on before the write finished — a different query, or none —
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
        delegate?.commandPalette(self, didCreate: note, from: rect)
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
        rows = []
        highlightedIndex = nil
        highlightPinned = false
        lastSpace = nil
        state = .idle
    }

    // MARK: - Editing the sheet

    /// Where the marker sits on screen, for the overlay and the fly-in.
    public func markerRect() -> CGRect {
        guard let textView, let marker = state.marker,
              let position = textView.position(from: textView.beginningOfDocument, offset: marker)
        else { return .zero }
        return textView.caretRect(for: position)
    }

    /// The marker and the query as they stand in the text right now.
    func querySpan() -> NSRange? {
        guard let textView, let marker = state.marker else { return nil }
        let length = markerLength + (state.query as NSString).length
        let end = min(marker + length, (textView.text as NSString).length)
        guard end >= marker else { return nil }
        return NSRange(location: marker, length: end - marker)
    }

    private func removeQueryText() {
        guard let textView, let span = querySpan(), span.length > 0 else { return }
        isApplyingOwnEdit = true
        textView.replaceText(in: span, with: "")
        textView.selectedRange = NSRange(location: span.location, length: 0)
        isApplyingOwnEdit = false
    }

    /// Replaces the marker and the query with `text`, caret after it, and
    /// closes the palette.
    private func replaceQuery(with text: String) {
        guard let textView, let span = querySpan() else {
            end()
            return
        }
        isApplyingOwnEdit = true
        textView.replaceText(in: span, with: text)
        textView.selectedRange = NSRange(location: span.location + (text as NSString).length, length: 0)
        isApplyingOwnEdit = false
        end()
    }

}

import Foundation

/// One entry of the document outline.
public struct HeadingEntry: Equatable, Sendable {
    public var level: Int
    /// The heading with its markup taken out.
    public var text: String
    public var lineRange: NSRange
    public var contentRange: NSRange

    public init(level: Int, text: String, lineRange: NSRange, contentRange: NSRange) {
        self.level = level
        self.text = text
        self.lineRange = lineRange
        self.contentRange = contentRange
    }
}

/// The scanned form of one Markdown document: a line table plus one scan per
/// line. An edit rescans from the first changed line and stops at the first
/// line whose incoming state matches the state it saw before, so a fence that
/// opens or closes restyles exactly as far as it reaches and no further.
///
/// Every stored range is relative to its own line start. A line therefore
/// keeps its scan when text before it changes length, and an edit costs the
/// lines it touches plus one offset shift.
public final class MarkdownDocumentModel {
    private let backing: NSMutableString?
    private var sharedText: NSString
    private var table: LineTable
    /// nil means the line still needs a scan.
    private var lines: [LineScan?]
    private var pendingLines: Range<Int>?
    /// The state the first line after the pending region saw before the edit.
    private var pendingBoundaryState: ScanState??

    /// Builds a model over a private copy of `text`.
    public convenience init(text: NSString = "") {
        self.init(mutableText: NSMutableString(string: text as String))
    }

    public convenience init(text: String) {
        self.init(mutableText: NSMutableString(string: text))
    }

    /// Builds a model over a string the model itself may change.
    public init(mutableText: NSMutableString) {
        backing = mutableText
        sharedText = mutableText
        table = LineTable(text: mutableText)
        lines = Array(repeating: nil, count: table.lineCount)
        pendingLines = 0..<table.lineCount
        pendingBoundaryState = .some(nil)
        flushPending()
    }

    /// Builds a model over a string somebody else changes, such as the text
    /// storage of a text view. The owner calls `apply(edit:replacementLength:)`
    /// after it has changed the string.
    public init(sharedText: NSString) {
        backing = nil
        self.sharedText = sharedText
        table = LineTable(text: sharedText)
        lines = Array(repeating: nil, count: table.lineCount)
        pendingLines = 0..<table.lineCount
        pendingBoundaryState = .some(nil)
        flushPending()
    }

    public var text: NSString { sharedText }

    public var lineCount: Int { table.lineCount }

    // MARK: - Editing

    /// Replaces the whole text and scans it again.
    public func setText(_ text: NSString) {
        if let backing {
            backing.setString(text as String)
        } else {
            sharedText = text
        }
        table = LineTable(text: sharedText)
        lines = Array(repeating: nil, count: table.lineCount)
        pendingLines = 0..<table.lineCount
        pendingBoundaryState = .some(nil)
        flushPending()
    }

    /// Changes the text this model owns and rescans. Returns the range whose
    /// scan changed.
    @discardableResult
    public func replaceCharacters(in range: NSRange, with string: String) -> NSRange {
        guard let backing else {
            preconditionFailure("This model does not own its text; change the text and call apply(edit:replacementLength:).")
        }
        let replacementLength = (string as NSString).length
        backing.replaceCharacters(in: range, with: string)
        apply(edit: range, replacementLength: replacementLength)
        return rescan(afterEditIn: NSRange(location: range.location, length: replacementLength))
    }

    /// Brings the line table back in step after the text changed. `edit` is
    /// the range that was replaced, in the text as it was before the change.
    public func apply(edit: NSRange, replacementLength: Int) {
        let splice = table.apply(edit: edit, replacementLength: replacementLength, text: sharedText)
        let lastRemoved = splice.removed.upperBound - 1
        let boundary = lastRemoved < lines.count ? lines[lastRemoved] : nil
        lines.replaceSubrange(splice.removed, with: Array(repeating: nil, count: splice.insertedCount))
        let first = splice.removed.lowerBound
        let end = first + splice.insertedCount
        if let existing = pendingLines {
            pendingLines = min(existing.lowerBound, first)..<max(existing.upperBound, end)
            pendingBoundaryState = .some(nil)
        } else {
            pendingLines = first..<end
            pendingBoundaryState = .some(boundary?.stateAfter)
        }
    }

    /// Rescans from the first line the edit touched and stops as soon as a
    /// line would see the state it saw before. Returns the text range whose
    /// scan changed.
    @discardableResult
    public func rescan(afterEditIn range: NSRange) -> NSRange {
        var first = table.lineIndex(at: range.location)
        var last = table.lineIndex(at: range.location + range.length)
        var boundaryState: ScanState?
        if let pending = pendingLines {
            first = min(first, pending.lowerBound)
            last = max(last, pending.upperBound - 1)
            boundaryState = pendingBoundaryState.flatMap { $0 }
        }
        first = min(first, max(0, lines.count - 1))
        pendingLines = nil
        pendingBoundaryState = nil

        var incoming = first == 0 ? ScanState.initial : (lines[first - 1]?.stateAfter ?? .initial)
        var oldIncoming: ScanState? = incoming
        var index = first
        var lastRescanned = first - 1
        while index < lines.count {
            if index > last, let old = oldIncoming, old == incoming, lines[index] != nil { break }
            let previous = lines[index]
            let scan = MarkdownScanner.scanLineRelative(in: sharedText, lineRange: table.lineRange(at: index), state: incoming)
            lines[index] = scan
            lastRescanned = index
            oldIncoming = index == last ? boundaryState : previous?.stateAfter
            incoming = scan.stateAfter
            index += 1
        }

        guard lastRescanned >= first else {
            return NSRange(location: table.lineRange(at: first).location, length: 0)
        }
        let start = table.lineRange(at: first).location
        let endLine = table.lineRange(at: lastRescanned)
        return NSRange(location: start, length: endLine.location + endLine.length - start)
    }

    private func flushPending() {
        guard let pending = pendingLines else { return }
        let first = min(pending.lowerBound, table.lineCount - 1)
        let last = min(max(pending.upperBound - 1, first), table.lineCount - 1)
        let start = table.lineRange(at: first)
        let end = table.lineRange(at: last)
        rescan(afterEditIn: NSRange(location: start.location, length: end.location + end.length - start.location))
    }

    // MARK: - Reading

    public func lineIndex(at offset: Int) -> Int { table.lineIndex(at: offset) }

    /// The whole line, its terminator included.
    public func lineRange(at index: Int) -> NSRange { table.lineRange(at: index) }

    /// The scan of one line, with absolute ranges.
    public func lineScan(at index: Int) -> LineScan {
        flushPending()
        let scan = lines[index] ?? MarkdownScanner.scanLineRelative(in: sharedText, lineRange: table.lineRange(at: index), state: .initial)
        return scan.offsetting(by: table.lineRange(at: index).location)
    }

    public func block(at offset: Int) -> BlockToken {
        lineScan(at: table.lineIndex(at: offset)).block
    }

    public func blocks(in range: NSRange) -> [BlockToken] {
        flushPending()
        let first = table.lineIndex(at: range.location)
        let last = table.lineIndex(at: range.location + max(0, range.length - (range.length > 0 ? 1 : 0)))
        return (first...max(first, last)).map { lineScan(at: $0).block }
    }

    public func inlines(in range: NSRange) -> [InlineToken] {
        blocksAndInlines(in: range).flatMap { $0.inlines }
    }

    /// The scans of every line the range touches.
    public func blocksAndInlines(in range: NSRange) -> [LineScan] {
        flushPending()
        let first = table.lineIndex(at: range.location)
        let last = table.lineIndex(at: range.location + max(0, range.length - (range.length > 0 ? 1 : 0)))
        return (first...max(first, last)).map { lineScan(at: $0) }
    }

    /// Every line, in order, with absolute ranges. Export walks this.
    public func allLineScans() -> [LineScan] {
        flushPending()
        return (0..<table.lineCount).map { lineScan(at: $0) }
    }

    public func headings() -> [HeadingEntry] {
        flushPending()
        var out: [HeadingEntry] = []
        for index in 0..<table.lineCount {
            let scan = lineScan(at: index)
            guard case .heading(let level) = scan.block.kind else { continue }
            out.append(HeadingEntry(
                level: level,
                text: InlineMarkup.plainText(of: scan.block.contentRange, in: sharedText, inlines: scan.inlines),
                lineRange: scan.block.lineRange,
                contentRange: scan.block.contentRange))
        }
        return out
    }

    public func firstHeadingText() -> String? {
        flushPending()
        for index in 0..<table.lineCount {
            let scan = lineScan(at: index)
            guard case .heading = scan.block.kind else { continue }
            let text = InlineMarkup.plainText(of: scan.block.contentRange, in: sharedText, inlines: scan.inlines)
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// The run of plain paragraph lines around `offset`. Any other block kind
    /// is its own unit, so a list item or a heading focuses on its own.
    public func paragraphRange(containing offset: Int) -> NSRange {
        flushPending()
        let index = table.lineIndex(at: offset)
        guard case .paragraph = lineScan(at: index).block.kind else {
            return table.lineRange(at: index)
        }
        var first = index
        while first > 0, case .paragraph = lineScan(at: first - 1).block.kind { first -= 1 }
        var last = index
        while last + 1 < table.lineCount, case .paragraph = lineScan(at: last + 1).block.kind { last += 1 }
        let start = table.lineRange(at: first)
        let end = table.lineRange(at: last)
        return NSRange(location: start.location, length: end.location + end.length - start.location)
    }
}

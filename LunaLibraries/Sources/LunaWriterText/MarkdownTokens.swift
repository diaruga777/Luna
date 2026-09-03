import Foundation

/// A task box on a list item.
public enum TaskState: String, Codable, Sendable, CaseIterable {
    case unchecked, checked
}

/// What one line is. A line is exactly one block; Luna Writer never spans a
/// block token over two lines, so a rescan can start and stop at a line.
public enum BlockKind: Equatable, Sendable {
    case heading(level: Int)
    case paragraph
    case blockquote(depth: Int)
    case listItem(ordered: Bool, indent: Int, task: TaskState?)
    /// A line inside a fence. The language comes from the opening delimiter.
    case fencedCode(language: String?)
    /// The ``` or ~~~ line that opens or closes a fence.
    case fenceDelimiter
    case thematicBreak
    case tableRow(isHeader: Bool)
    case tableDelimiter
    case footnoteDefinition(label: String)
    case blank
}

public struct BlockToken: Equatable, Sendable {
    /// The whole line, its terminator included, so blocks tile the document.
    public var lineRange: NSRange
    public var kind: BlockKind
    /// The syntax characters, for example the leading hashes of a heading.
    public var markupRanges: [NSRange]
    /// The line without its terminator and without the leading block markup.
    public var contentRange: NSRange

    public init(lineRange: NSRange, kind: BlockKind, markupRanges: [NSRange] = [], contentRange: NSRange) {
        self.lineRange = lineRange
        self.kind = kind
        self.markupRanges = markupRanges
        self.contentRange = contentRange
    }
}

public enum InlineKind: Equatable, Sendable {
    case emphasis
    case strong
    case strikethrough
    /// ==highlighted==
    case highlight
    case code
    case link(destination: String)
    case image(destination: String)
    case autolink
    case footnoteReference(label: String)
    case hardBreak
}

public struct InlineToken: Equatable, Sendable {
    public var range: NSRange
    public var kind: InlineKind
    public var markupRanges: [NSRange]

    public init(range: NSRange, kind: InlineKind, markupRanges: [NSRange] = []) {
        self.range = range
        self.kind = kind
        self.markupRanges = markupRanges
    }

    /// The text between the opening and the closing markup. A token whose
    /// markup covers the whole range, such as a hard break, has none.
    public var contentRange: NSRange {
        var start = range.location
        var end = range.location + range.length
        if let lead = markupRanges.first, lead.location == range.location {
            start = lead.location + lead.length
        }
        if let trail = markupRanges.last, trail.location + trail.length == range.location + range.length {
            end = trail.location
        }
        if end < start { end = start }
        return NSRange(location: start, length: end - start)
    }
}

/// What a line leaves behind for the next line. Two lines with the same text
/// and the same incoming state scan the same, which is what lets a rescan
/// stop early.
public struct ScanState: Equatable, Sendable {
    /// The character and run length that opened the fence, for example
    /// backtick, 3. Only a run of the same character at least this wide, at
    /// the same or lesser indent, closes it.
    public struct FenceMarker: Equatable, Sendable {
        public var marker: unichar
        public var width: Int

        public init(marker: unichar, width: Int) {
            self.marker = marker
            self.width = width
        }
    }

    public var inFence: FenceMarker?
    /// The info string of the open fence.
    public var fenceLanguage: String?
    /// True once a table delimiter row has been seen.
    public var inTable: Bool

    public init(inFence: FenceMarker? = nil, fenceLanguage: String? = nil, inTable: Bool = false) {
        self.inFence = inFence
        self.fenceLanguage = fenceLanguage
        self.inTable = inTable
    }

    public static let initial = ScanState()
}

public struct LineScan: Equatable, Sendable {
    public var block: BlockToken
    public var inlines: [InlineToken]
    public var stateAfter: ScanState

    public init(block: BlockToken, inlines: [InlineToken], stateAfter: ScanState) {
        self.block = block
        self.inlines = inlines
        self.stateAfter = stateAfter
    }
}

extension BlockToken {
    func offsetting(by delta: Int) -> BlockToken {
        guard delta != 0 else { return self }
        return BlockToken(
            lineRange: NSRange(location: lineRange.location + delta, length: lineRange.length),
            kind: kind,
            markupRanges: markupRanges.map { NSRange(location: $0.location + delta, length: $0.length) },
            contentRange: NSRange(location: contentRange.location + delta, length: contentRange.length)
        )
    }
}

extension InlineToken {
    func offsetting(by delta: Int) -> InlineToken {
        guard delta != 0 else { return self }
        return InlineToken(
            range: NSRange(location: range.location + delta, length: range.length),
            kind: kind,
            markupRanges: markupRanges.map { NSRange(location: $0.location + delta, length: $0.length) }
        )
    }
}

extension LineScan {
    func offsetting(by delta: Int) -> LineScan {
        guard delta != 0 else { return self }
        return LineScan(
            block: block.offsetting(by: delta),
            inlines: inlines.map { $0.offsetting(by: delta) },
            stateAfter: stateAfter
        )
    }
}

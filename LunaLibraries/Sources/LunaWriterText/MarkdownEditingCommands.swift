import Foundation

/// One replacement in the text.
public struct TextEdit: Equatable, Sendable {
    /// The range in the text as it is now.
    public var range: NSRange
    public var replacement: String

    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}

public enum MarkdownListKind: Equatable, Sendable {
    case bullet
    case ordered
    case task
}

/// The pure text transforms behind the editor toolbar and the Return key.
/// Every command answers a list of edits, ordered from the end of the text
/// backwards, so the caller can apply them one after another through its own
/// undo manager without moving any offsets.
public enum MarkdownEditingCommands {

    public static let bulletMarker = "- "
    public static let indentUnit = "    "

    // MARK: - Applying

    /// Applies edits in the order they are given. Returns the range the new
    /// text occupies, so the caller can place the caret.
    @discardableResult
    public static func apply(_ edits: [TextEdit], to text: NSMutableString) -> NSRange {
        var lowest = Int.max
        var highest = 0
        for edit in edits {
            text.replaceCharacters(in: edit.range, with: edit.replacement)
            let length = (edit.replacement as NSString).length
            lowest = min(lowest, edit.range.location)
            highest = max(highest, edit.range.location + length)
        }
        guard lowest != Int.max else { return NSRange(location: 0, length: 0) }
        return NSRange(location: lowest, length: max(0, highest - lowest))
    }

    // MARK: - Inline

    /// Wraps the selection in `marker`, or takes the marker off when it is
    /// already there. An empty selection opens an empty pair.
    public static func toggleWrap(_ range: NSRange, marker: String, in text: NSString) -> [TextEdit] {
        let markerLength = (marker as NSString).length
        guard markerLength > 0, NSMaxRange(range) <= text.length else { return [] }

        if range.length >= markerLength * 2,
           text.substring(with: NSRange(location: range.location, length: markerLength)) == marker,
           text.substring(with: NSRange(location: NSMaxRange(range) - markerLength, length: markerLength)) == marker {
            return [
                TextEdit(range: NSRange(location: NSMaxRange(range) - markerLength, length: markerLength), replacement: ""),
                TextEdit(range: NSRange(location: range.location, length: markerLength), replacement: ""),
            ]
        }

        let before = NSRange(location: range.location - markerLength, length: markerLength)
        let after = NSRange(location: NSMaxRange(range), length: markerLength)
        if before.location >= 0, NSMaxRange(after) <= text.length,
           text.substring(with: before) == marker, text.substring(with: after) == marker {
            return [TextEdit(range: after, replacement: ""), TextEdit(range: before, replacement: "")]
        }

        return [
            TextEdit(range: NSRange(location: NSMaxRange(range), length: 0), replacement: marker),
            TextEdit(range: NSRange(location: range.location, length: 0), replacement: marker),
        ]
    }

    // MARK: - Blocks

    /// Sets the heading level of the paragraph at `offset`. Level zero takes
    /// the heading off.
    public static func setHeading(_ level: Int, paragraphAt offset: Int, in text: NSString) -> [TextEdit] {
        guard level >= 0, level <= 6 else { return [] }
        let line = lineRange(at: offset, in: text)
        let start = firstNonSpace(in: line, of: text)
        var end = start
        var hashes = 0
        while end < NSMaxRange(line), text.character(at: end) == 0x23 { end += 1; hashes += 1 }
        if hashes > 0, hashes <= 6 {
            while end < NSMaxRange(line), isSpaceOrTab(text.character(at: end)) { end += 1 }
        } else {
            end = start
            hashes = 0
        }
        if hashes == level { return [] }
        let replacement = level == 0 ? "" : String(repeating: "#", count: level) + " "
        return [TextEdit(range: NSRange(location: start, length: end - start), replacement: replacement)]
    }

    /// Turns every line the range touches into a list of `kind`, or takes the
    /// markers off when they are already that kind.
    public static func toggleList(_ kind: MarkdownListKind, in range: NSRange, of text: NSString) -> [TextEdit] {
        let lines = self.lines(touching: range, in: text)
        guard !lines.isEmpty else { return [] }
        let markers = lines.map { marker(ofLine: $0, in: text) }
        let contentful = zip(lines, markers).filter { !isBlank($0.0, in: text) }
        guard !contentful.isEmpty else { return [] }
        let alreadyThatKind = contentful.allSatisfy { $0.1?.kind == kind }

        var edits: [TextEdit] = []
        var number = 1
        for (line, existing) in zip(lines, markers) {
            guard !isBlank(line, in: text) else { continue }
            let start = firstNonSpace(in: line, of: text)
            let existingRange = NSRange(location: start, length: (existing?.contentStart ?? start) - start)
            if alreadyThatKind {
                edits.append(TextEdit(range: existingRange, replacement: ""))
                continue
            }
            let replacement: String
            switch kind {
            case .bullet: replacement = bulletMarker
            case .ordered: replacement = "\(number). "
            case .task: replacement = bulletMarker + "[ ] "
            }
            number += 1
            edits.append(TextEdit(range: existingRange, replacement: replacement))
        }
        return edits.reversed()
    }

    /// Ticks or unticks the task box on the line at `offset`, and gives a
    /// line that has none a fresh unticked box.
    public static func toggleTask(at offset: Int, in text: NSString) -> [TextEdit] {
        let line = lineRange(at: offset, in: text)
        guard !isBlank(line, in: text) else { return [] }
        let start = firstNonSpace(in: line, of: text)
        guard let existing = marker(ofLine: line, in: text) else {
            return [TextEdit(range: NSRange(location: start, length: 0), replacement: bulletMarker + "[ ] ")]
        }
        guard let box = existing.taskBox else {
            return [TextEdit(range: NSRange(location: existing.contentStart, length: 0), replacement: "[ ] ")]
        }
        let ticked = existing.task == .checked
        return [TextEdit(range: box, replacement: ticked ? "[ ]" : "[x]")]
    }

    /// What Return should do on the line at `offset`. nil means the caller
    /// inserts a plain line break.
    public static func continueList(onReturnAt offset: Int, in text: NSString) -> [TextEdit]? {
        let line = lineRange(at: offset, in: text)
        let start = firstNonSpace(in: line, of: text)
        if let existing = marker(ofLine: line, in: text) {
            let contentEnd = trimmedEnd(of: line, in: text)
            if existing.contentStart >= contentEnd {
                // An empty item ends the list rather than making another.
                return [TextEdit(range: NSRange(location: start, length: existing.contentStart - start), replacement: "")]
            }
            var next = text.substring(with: NSRange(location: line.location, length: start - line.location))
            switch existing.kind {
            case .bullet: next += text.substring(with: NSRange(location: start, length: existing.markerLength))
            case .task: next += text.substring(with: NSRange(location: start, length: existing.markerLength)) + "[ ] "
            case .ordered: next += "\(existing.number + 1). "
            }
            return [TextEdit(range: NSRange(location: offset, length: 0), replacement: "\n" + next)]
        }
        if let quote = blockquotePrefix(ofLine: line, in: text), trimmedEnd(of: line, in: text) > quote.end {
            let prefix = text.substring(with: NSRange(location: line.location, length: quote.end - line.location))
            return [TextEdit(range: NSRange(location: offset, length: 0), replacement: "\n" + prefix)]
        }
        return nil
    }

    public static func indent(_ range: NSRange, in text: NSString, using unit: String = indentUnit) -> [TextEdit] {
        lines(touching: range, in: text)
            .filter { !isBlank($0, in: text) }
            .map { TextEdit(range: NSRange(location: $0.location, length: 0), replacement: unit) }
            .reversed()
    }

    public static func outdent(_ range: NSRange, in text: NSString, using unit: String = indentUnit) -> [TextEdit] {
        let width = (unit as NSString).length
        var edits: [TextEdit] = []
        for line in lines(touching: range, in: text) {
            guard line.length > 0 else { continue }
            if text.character(at: line.location) == 0x09 {
                edits.append(TextEdit(range: NSRange(location: line.location, length: 1), replacement: ""))
                continue
            }
            var removed = 0
            while removed < width, line.location + removed < NSMaxRange(line),
                  text.character(at: line.location + removed) == 0x20 { removed += 1 }
            guard removed > 0 else { continue }
            edits.append(TextEdit(range: NSRange(location: line.location, length: removed), replacement: ""))
        }
        return edits.reversed()
    }

    // MARK: - Line reading

    struct LineMarker {
        var kind: MarkdownListKind
        /// Where the item's own text starts, past the marker and any box.
        var contentStart: Int
        var markerLength: Int
        var number: Int
        var task: TaskState?
        var taskBox: NSRange?
    }

    static func marker(ofLine line: NSRange, in text: NSString) -> LineMarker? {
        var index = firstNonSpace(in: line, of: text)
        let end = NSMaxRange(line)
        guard index < end else { return nil }
        let first = text.character(at: index)
        var kind: MarkdownListKind
        var number = 0
        var markerLength = 0

        if first == 0x2D || first == 0x2B || first == 0x2A {
            let next = index + 1
            guard next < end, isSpaceOrTab(text.character(at: next)) else { return nil }
            kind = .bullet
            index = next
        } else if isDigit(first) {
            var digits = index
            while digits < end, isDigit(text.character(at: digits)) { digits += 1 }
            guard digits < end, text.character(at: digits) == 0x2E || text.character(at: digits) == 0x29 else { return nil }
            guard digits + 1 < end, isSpaceOrTab(text.character(at: digits + 1)) else { return nil }
            number = Int(text.substring(with: NSRange(location: index, length: digits - index))) ?? 0
            kind = .ordered
            index = digits + 1
        } else {
            return nil
        }

        let markerStart = firstNonSpace(in: line, of: text)
        while index < end, isSpaceOrTab(text.character(at: index)) { index += 1 }
        markerLength = index - markerStart

        var task: TaskState?
        var taskBox: NSRange?
        if kind == .bullet, index + 2 < end, text.character(at: index) == 0x5B, text.character(at: index + 2) == 0x5D {
            let box = text.character(at: index + 1)
            let closes = index + 3 >= end || isSpaceOrTab(text.character(at: index + 3)) || text.character(at: index + 3) == 0x0A
            if closes, box == 0x20 || box == 0x78 || box == 0x58 {
                task = box == 0x20 ? .unchecked : .checked
                taskBox = NSRange(location: index, length: 3)
                kind = .task
                index += 3
                while index < end, isSpaceOrTab(text.character(at: index)) { index += 1 }
            }
        }
        return LineMarker(kind: kind, contentStart: index, markerLength: markerLength, number: number, task: task, taskBox: taskBox)
    }

    private static func blockquotePrefix(ofLine line: NSRange, in text: NSString) -> (end: Int, depth: Int)? {
        var index = firstNonSpace(in: line, of: text)
        let end = NSMaxRange(line)
        var depth = 0
        while index < end, text.character(at: index) == 0x3E {
            depth += 1
            index += 1
            if index < end, isSpaceOrTab(text.character(at: index)) { index += 1 }
        }
        return depth > 0 ? (index, depth) : nil
    }

    static func lineRange(at offset: Int, in text: NSString) -> NSRange {
        let clamped = min(max(0, offset), text.length)
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }
        return text.lineRange(for: NSRange(location: min(clamped, text.length - 1), length: 0))
    }

    static func lines(touching range: NSRange, in text: NSString) -> [NSRange] {
        guard text.length > 0 else { return [] }
        var out: [NSRange] = []
        var location = min(max(0, range.location), text.length - 1)
        let end = min(max(NSMaxRange(range), range.location + 1), text.length)
        while location < end {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            out.append(line)
            guard NSMaxRange(line) > location else { break }
            location = NSMaxRange(line)
        }
        return out
    }

    private static func firstNonSpace(in line: NSRange, of text: NSString) -> Int {
        var index = line.location
        while index < NSMaxRange(line), isSpaceOrTab(text.character(at: index)) { index += 1 }
        return index
    }

    private static func trimmedEnd(of line: NSRange, in text: NSString) -> Int {
        var end = NSMaxRange(line)
        while end > line.location, isTrailing(text.character(at: end - 1)) { end -= 1 }
        return end
    }

    private static func isBlank(_ line: NSRange, in text: NSString) -> Bool {
        firstNonSpace(in: line, of: text) >= trimmedEnd(of: line, in: text)
    }

    private static func isTrailing(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
    }

    private static func isSpaceOrTab(_ unit: unichar) -> Bool { unit == 0x20 || unit == 0x09 }

    private static func isDigit(_ unit: unichar) -> Bool { unit >= 0x30 && unit <= 0x39 }
}

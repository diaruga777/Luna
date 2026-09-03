import Foundation

/// The start offset of every line, in UTF-16 units. A document with no text
/// still has one line, so a line index is always valid.
///
/// The table holds offsets only. Line content and its scan live beside it in
/// `MarkdownDocumentModel`, keyed by the same index.
public struct LineTable: Equatable {
    private(set) var starts: [Int]
    private(set) var length: Int

    public init(text: NSString) {
        length = text.length
        starts = [0]
        LineTable.appendStarts(of: text, in: NSRange(location: 0, length: text.length), into: &starts)
    }

    public var lineCount: Int { starts.count }

    /// The line that holds `offset`. An offset past the end reads as the last
    /// line, so a caret at the end of the text always has a line.
    public func lineIndex(at offset: Int) -> Int {
        let target = min(max(offset, 0), length)
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= target { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The whole line, its terminator included.
    public func lineRange(at index: Int) -> NSRange {
        let start = starts[index]
        let end = index + 1 < starts.count ? starts[index + 1] : length
        return NSRange(location: start, length: end - start)
    }

    /// Replaces `edit` with `replacementLength` units of the already-updated
    /// `text`. Returns the line indices that need a new scan and the last
    /// line the edit removed, so the caller can splice its own per-line data.
    mutating func apply(edit: NSRange, replacementLength: Int, text: NSString) -> (removed: Range<Int>, insertedCount: Int) {
        let delta = replacementLength - edit.length
        var firstLine = lineIndex(at: edit.location)
        // A CR before the edit may pair with a LF the edit brings, which moves
        // the boundary of the line before this one.
        if firstLine > 0, starts[firstLine] == edit.location, text.character(at: edit.location - 1) == 0x0D {
            firstLine -= 1
        }
        let lastLine = max(firstLine, lineIndex(at: edit.location + edit.length))

        let oldRegionEnd = lastLine + 1 < starts.count ? starts[lastLine + 1] : length
        let regionStart = starts[firstLine]
        // `oldRegionEnd` is always a line start in the OLD text, and every unit
        // from the edit's end to `oldRegionEnd` is untouched. The character
        // right before `oldRegionEnd` is therefore unchanged by the edit, and
        // so is whatever it is (or isn't) paired with, so `oldRegionEnd + delta`
        // is already a line start in the NEW text: it needs no search forward.
        let regionEnd = oldRegionEnd + delta
        let newLength = length + delta

        // A delete that takes every line from `firstLine` to the end leaves no
        // line to start at `regionStart`: the whole run goes.
        var inserted: [Int] = (regionStart == regionEnd && firstLine > 0) ? [] : [regionStart]
        LineTable.appendStarts(of: text, in: NSRange(location: regionStart, length: regionEnd - regionStart), into: &inserted)

        starts.replaceSubrange(firstLine...lastLine, with: inserted)
        length = newLength
        if delta != 0 {
            var index = firstLine + inserted.count
            while index < starts.count {
                starts[index] += delta
                index += 1
            }
        }
        return (firstLine..<(lastLine + 1), inserted.count)
    }

    /// True when `offset` starts a line: the text end, the text start, or the
    /// position just after a terminator. Matches `NSString.lineRange(for:)`,
    /// which also breaks after NEL (U+0085) — but, measured directly, not
    /// after form feed or vertical tab, despite both being in
    /// `NSCharacterSet.newlines`; `lineRange(for:)` uses its own narrower
    /// notion of a line terminator.
    private static func isLineBoundary(_ offset: Int, in text: NSString, length: Int) -> Bool {
        if offset >= length { return true }
        if offset <= 0 { return true }
        let previous = text.character(at: offset - 1)
        if previous == 0x0A || previous == 0x0085 || previous == 0x2028 || previous == 0x2029 { return true }
        if previous == 0x0D { return text.character(at: offset) != 0x0A }
        return false
    }

    /// Appends every line start strictly inside `range`. A start at the end of
    /// the range belongs to the next region and is left out.
    private static func appendStarts(of text: NSString, in range: NSRange, into out: inout [Int]) {
        let end = range.location + range.length
        guard range.length > 0 else { return }
        let chunkSize = 8192
        var buffer = [unichar](repeating: 0, count: min(chunkSize, range.length))
        var base = range.location
        while base < end {
            let count = min(chunkSize, end - base)
            text.getCharacters(&buffer, range: NSRange(location: base, length: count))
            var k = 0
            while k < count {
                let unit = buffer[k]
                if unit == 0x0A || unit == 0x0085 || unit == 0x2028 || unit == 0x2029 {
                    let start = base + k + 1
                    if start < end { out.append(start) }
                    k += 1
                } else if unit == 0x0D {
                    var advance = 1
                    if k + 1 < count {
                        if buffer[k + 1] == 0x0A { advance = 2 }
                    } else if base + k + 1 < end, text.character(at: base + k + 1) == 0x0A {
                        advance = 2
                    }
                    let start = base + k + advance
                    if start < end { out.append(start) }
                    k += advance
                } else {
                    k += 1
                }
            }
            // A CR/LF pair split across the chunk boundary advances `k` one
            // past `count`: the LF was already read from the live text and
            // its start already appended, so the next chunk must not re-read it.
            base += k > count ? k : count
        }
    }
}

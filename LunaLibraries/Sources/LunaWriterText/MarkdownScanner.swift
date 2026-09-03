import Foundation

/// Line-at-a-time Markdown tokenizer. It reads one line of UTF-16 units and
/// answers what block that line is, what inline spans it holds, and what it
/// leaves for the next line. It never looks at another line, so the document
/// model can rescan from any line and stop as soon as the state settles.
///
/// Two deliberate simplifications, both invisible in a writing surface:
/// a `---` line under a paragraph is a thematic break, not a setext heading,
/// and an inline span never crosses a line break.
public enum MarkdownScanner {

    // MARK: - Entry points

    /// Scans the line at `lineRange` of `text`. The returned ranges are
    /// absolute. `lineRange` includes the line terminator.
    public static func scanLine(in text: NSString, lineRange: NSRange, state: ScanState) -> LineScan {
        scanLineRelative(in: text, lineRange: lineRange, state: state).offsetting(by: lineRange.location)
    }

    /// The allocation-light form the document model uses: the ranges are
    /// relative to the line start, so a line keeps its scan when the text
    /// before it changes length.
    static func scanLineRelative(in text: NSString, lineRange: NSRange, state: ScanState) -> LineScan {
        guard lineRange.length > 0 else {
            return blankScan(lineRange: NSRange(location: 0, length: 0), state: state)
        }
        return withUnsafeTemporaryAllocation(of: unichar.self, capacity: lineRange.length) { raw -> LineScan in
            guard let base = raw.baseAddress else {
                return blankScan(lineRange: NSRange(location: 0, length: 0), state: state)
            }
            text.getCharacters(base, range: lineRange)
            return scan(UnsafeBufferPointer(start: base, count: lineRange.length), state: state)
        }
    }

    private static func blankScan(lineRange: NSRange, state: ScanState) -> LineScan {
        var after = state
        after.inTable = false
        let block = BlockToken(
            lineRange: lineRange,
            kind: state.inFence == nil ? .blank : .fencedCode(language: state.fenceLanguage),
            markupRanges: [],
            contentRange: NSRange(location: lineRange.location, length: 0)
        )
        return LineScan(block: block, inlines: [], stateAfter: state.inFence == nil ? after : state)
    }

    // MARK: - Block scan

    private static func scan(_ b: UnsafeBufferPointer<unichar>, state: ScanState) -> LineScan {
        let total = b.count
        var content = total
        if content > 0 {
            let last = b[content - 1]
            if last == U.newline {
                content -= 1
                if content > 0, b[content - 1] == U.carriageReturn { content -= 1 }
            } else if last == U.carriageReturn || last == U.lineSeparator || last == U.paragraphSeparator {
                content -= 1
            }
        }
        let lineRange = NSRange(location: 0, length: total)

        var i = 0
        var column = 0
        while i < content, b[i] == U.space || b[i] == U.tab {
            column += (b[i] == U.tab) ? 4 : 1
            i += 1
        }
        let start = i
        var end = content
        while end > start, b[end - 1] == U.space || b[end - 1] == U.tab { end -= 1 }

        var after = state

        // Inside a fence nothing else is Markdown; only a matching delimiter closes it.
        if let fence = state.inFence {
            let run = runLength(b, of: fence.marker, from: start, limit: end)
            if column <= 3, run >= fence.width, start + run == end {
                after.inFence = nil
                after.fenceLanguage = nil
                after.inTable = false
                return LineScan(
                    block: BlockToken(lineRange: lineRange, kind: .fenceDelimiter,
                                      markupRanges: [NSRange(location: start, length: end - start)],
                                      contentRange: NSRange(location: end, length: 0)),
                    inlines: [], stateAfter: after)
            }
            // A fenced line keeps its own indentation: only the leading
            // whitespace the editor greys out for other blocks is markup here.
            return LineScan(
                block: BlockToken(lineRange: lineRange, kind: .fencedCode(language: state.fenceLanguage),
                                  markupRanges: [],
                                  contentRange: NSRange(location: 0, length: content)),
                inlines: [], stateAfter: state)
        }

        after.inTable = false

        if start >= content {
            return LineScan(
                block: BlockToken(lineRange: lineRange, kind: .blank, markupRanges: [],
                                  contentRange: NSRange(location: start, length: 0)),
                inlines: [], stateAfter: after)
        }

        let first = b[start]

        // Fence opening.
        if column <= 3, first == U.backtick || first == U.tilde {
            let run = runLength(b, of: first, from: start, limit: end)
            let infoStart = start + run
            let infoIsClean = first == U.tilde || !contains(b, U.backtick, from: infoStart, to: end)
            if run >= 3, infoIsClean {
                after.inFence = ScanState.FenceMarker(marker: first, width: run)
                after.fenceLanguage = infoWord(b, from: infoStart, to: end)
                return LineScan(
                    block: BlockToken(lineRange: lineRange, kind: .fenceDelimiter,
                                      markupRanges: [NSRange(location: start, length: end - start)],
                                      contentRange: NSRange(location: end, length: 0)),
                    inlines: [], stateAfter: after)
            }
        }

        // Thematic break: three or more of one mark, nothing else but spaces.
        if column <= 3, first == U.hyphen || first == U.asterisk || first == U.underscore {
            var marks = 0
            var k = start
            var pure = true
            while k < end {
                if b[k] == first { marks += 1 } else if b[k] != U.space && b[k] != U.tab { pure = false; break }
                k += 1
            }
            if pure, marks >= 3 {
                return LineScan(
                    block: BlockToken(lineRange: lineRange, kind: .thematicBreak,
                                      markupRanges: [NSRange(location: start, length: end - start)],
                                      contentRange: NSRange(location: end, length: 0)),
                    inlines: [], stateAfter: after)
            }
        }

        // ATX heading.
        if column <= 3, first == U.hash {
            let level = runLength(b, of: U.hash, from: start, limit: end)
            let afterHashes = start + level
            if level <= 6, afterHashes == end || b[afterHashes] == U.space || b[afterHashes] == U.tab {
                var markup = [NSRange(location: start, length: level)]
                var textStart = afterHashes
                while textStart < end, b[textStart] == U.space || b[textStart] == U.tab { textStart += 1 }
                var textEnd = end
                var closing = textEnd
                while closing > textStart, b[closing - 1] == U.hash { closing -= 1 }
                if closing < textEnd, closing > textStart, b[closing - 1] == U.space {
                    markup.append(NSRange(location: closing, length: textEnd - closing))
                    textEnd = closing
                    while textEnd > textStart, b[textEnd - 1] == U.space { textEnd -= 1 }
                }
                let contentRange = NSRange(location: textStart, length: max(0, textEnd - textStart))
                var inlines: [InlineToken] = []
                scanInlines(b, from: contentRange.location, to: textEnd, depth: 0, into: &inlines)
                return LineScan(
                    block: BlockToken(lineRange: lineRange, kind: .heading(level: level),
                                      markupRanges: markup, contentRange: contentRange),
                    inlines: inlines, stateAfter: after)
            }
        }

        // Blockquote.
        if column <= 3, first == U.greaterThan {
            var depth = 0
            var k = start
            while k < end, b[k] == U.greaterThan {
                depth += 1
                k += 1
                if k < end, b[k] == U.space || b[k] == U.tab { k += 1 }
            }
            let contentRange = NSRange(location: k, length: max(0, content - k))
            var inlines: [InlineToken] = []
            scanInlines(b, from: k, to: end, depth: 0, into: &inlines)
            appendHardBreak(b, contentStart: k, trimmedEnd: end, rawEnd: content, into: &inlines)
            return LineScan(
                block: BlockToken(lineRange: lineRange, kind: .blockquote(depth: depth),
                                  markupRanges: [NSRange(location: start, length: k - start)],
                                  contentRange: contentRange),
                inlines: inlines, stateAfter: after)
        }

        // Footnote definition.
        if column <= 3, first == U.leftBracket, start + 1 < end, b[start + 1] == U.caret {
            var k = start + 2
            while k < end, b[k] != U.rightBracket { k += 1 }
            if k < end, k + 1 < end, b[k + 1] == U.colon {
                let label = String(utf16CodeUnits: Array(b[(start + 2)..<k]), count: k - start - 2)
                var textStart = k + 2
                while textStart < end, b[textStart] == U.space || b[textStart] == U.tab { textStart += 1 }
                var inlines: [InlineToken] = []
                scanInlines(b, from: textStart, to: end, depth: 0, into: &inlines)
                return LineScan(
                    block: BlockToken(lineRange: lineRange, kind: .footnoteDefinition(label: label),
                                      markupRanges: [NSRange(location: start, length: textStart - start)],
                                      contentRange: NSRange(location: textStart, length: max(0, content - textStart))),
                    inlines: inlines, stateAfter: after)
            }
        }

        // List item.
        if let item = listMarker(b, start: start, end: end) {
            var markup = [NSRange(location: start, length: item.contentStart - start)]
            var task: TaskState?
            var textStart = item.contentStart
            if textStart + 2 < end, b[textStart] == U.leftBracket, b[textStart + 2] == U.rightBracket {
                let box = b[textStart + 1]
                let closes = textStart + 3 == end || b[textStart + 3] == U.space || b[textStart + 3] == U.tab
                if closes, box == U.space || box == U.lowerX || box == U.upperX {
                    task = (box == U.space) ? .unchecked : .checked
                    var boxEnd = textStart + 3
                    while boxEnd < end, b[boxEnd] == U.space || b[boxEnd] == U.tab { boxEnd += 1 }
                    markup.append(NSRange(location: textStart, length: boxEnd - textStart))
                    textStart = boxEnd
                }
            }
            var inlines: [InlineToken] = []
            scanInlines(b, from: textStart, to: end, depth: 0, into: &inlines)
            appendHardBreak(b, contentStart: textStart, trimmedEnd: end, rawEnd: content, into: &inlines)
            return LineScan(
                block: BlockToken(lineRange: lineRange,
                                  kind: .listItem(ordered: item.ordered, indent: column, task: task),
                                  markupRanges: markup,
                                  contentRange: NSRange(location: textStart, length: max(0, content - textStart))),
                inlines: inlines, stateAfter: after)
        }

        // Table rows. A delimiter row turns the table on; the row above it is
        // already tagged as a header because a `|` line outside a table can
        // only be one.
        if isTableDelimiter(b, from: start, to: end) {
            after.inTable = true
            return LineScan(
                block: BlockToken(lineRange: lineRange, kind: .tableDelimiter,
                                  markupRanges: [NSRange(location: start, length: end - start)],
                                  contentRange: NSRange(location: end, length: 0)),
                inlines: [], stateAfter: after)
        }
        if hasUnescapedPipe(b, from: start, to: end) {
            after.inTable = state.inTable
            var markup: [NSRange] = []
            var k = start
            while k < end {
                if b[k] == U.backslash { k += 2; continue }
                if b[k] == U.pipe { markup.append(NSRange(location: k, length: 1)) }
                k += 1
            }
            var inlines: [InlineToken] = []
            scanInlines(b, from: start, to: end, depth: 0, into: &inlines)
            return LineScan(
                block: BlockToken(lineRange: lineRange, kind: .tableRow(isHeader: !state.inTable),
                                  markupRanges: markup,
                                  contentRange: NSRange(location: start, length: max(0, content - start))),
                inlines: inlines, stateAfter: after)
        }

        var inlines: [InlineToken] = []
        scanInlines(b, from: start, to: end, depth: 0, into: &inlines)
        appendHardBreak(b, contentStart: start, trimmedEnd: end, rawEnd: content, into: &inlines)
        return LineScan(
            block: BlockToken(lineRange: lineRange, kind: .paragraph, markupRanges: [],
                              contentRange: NSRange(location: start, length: max(0, content - start))),
            inlines: inlines, stateAfter: after)
    }

    // MARK: - Block helpers

    private struct ListMarker {
        var ordered: Bool
        var contentStart: Int
    }

    private static func listMarker(_ b: UnsafeBufferPointer<unichar>, start: Int, end: Int) -> ListMarker? {
        guard start < end else { return nil }
        let first = b[start]
        if first == U.hyphen || first == U.plus || first == U.asterisk {
            let next = start + 1
            guard next == end || b[next] == U.space || b[next] == U.tab else { return nil }
            var k = next
            while k < end, b[k] == U.space || b[k] == U.tab { k += 1 }
            return ListMarker(ordered: false, contentStart: k)
        }
        if isDigit(first) {
            var k = start
            var digits = 0
            while k < end, isDigit(b[k]), digits < 9 { k += 1; digits += 1 }
            guard k < end, b[k] == U.period || b[k] == U.rightParen else { return nil }
            k += 1
            guard k == end || b[k] == U.space || b[k] == U.tab else { return nil }
            while k < end, b[k] == U.space || b[k] == U.tab { k += 1 }
            return ListMarker(ordered: true, contentStart: k)
        }
        return nil
    }

    private static func isTableDelimiter(_ b: UnsafeBufferPointer<unichar>, from: Int, to: Int) -> Bool {
        var sawDash = false
        var sawPipe = false
        for k in from..<to {
            switch b[k] {
            case U.pipe: sawPipe = true
            case U.hyphen: sawDash = true
            case U.colon, U.space, U.tab: break
            default: return false
            }
        }
        return sawDash && sawPipe
    }

    private static func hasUnescapedPipe(_ b: UnsafeBufferPointer<unichar>, from: Int, to: Int) -> Bool {
        var k = from
        while k < to {
            if b[k] == U.backslash { k += 2; continue }
            if b[k] == U.pipe { return true }
            k += 1
        }
        return false
    }

    private static func infoWord(_ b: UnsafeBufferPointer<unichar>, from: Int, to: Int) -> String? {
        var k = from
        while k < to, b[k] == U.space || b[k] == U.tab { k += 1 }
        var e = k
        while e < to, b[e] != U.space, b[e] != U.tab { e += 1 }
        guard e > k else { return nil }
        return String(utf16CodeUnits: Array(b[k..<e]), count: e - k)
    }

    private static func appendHardBreak(
        _ b: UnsafeBufferPointer<unichar>, contentStart: Int, trimmedEnd: Int, rawEnd: Int,
        into out: inout [InlineToken]
    ) {
        if rawEnd - trimmedEnd >= 2, trimmedEnd > contentStart {
            out.append(InlineToken(range: NSRange(location: trimmedEnd, length: rawEnd - trimmedEnd),
                                   kind: .hardBreak,
                                   markupRanges: [NSRange(location: trimmedEnd, length: rawEnd - trimmedEnd)]))
        } else if trimmedEnd > contentStart, b[trimmedEnd - 1] == U.backslash {
            out.append(InlineToken(range: NSRange(location: trimmedEnd - 1, length: 1), kind: .hardBreak,
                                   markupRanges: [NSRange(location: trimmedEnd - 1, length: 1)]))
        }
    }

    // MARK: - Inline scan

    private static let maxInlineDepth = 6

    private static func scanInlines(
        _ b: UnsafeBufferPointer<unichar>, from: Int, to: Int, depth: Int, into out: inout [InlineToken]
    ) {
        guard depth < maxInlineDepth, from < to else { return }
        var i = from
        while i < to {
            let c = b[i]
            switch c {
            case U.backslash:
                i += 2

            case U.backtick:
                let run = runLength(b, of: U.backtick, from: i, limit: to)
                if let close = findBacktickRun(b, length: run, from: i + run, to: to) {
                    out.append(InlineToken(range: NSRange(location: i, length: close + run - i), kind: .code,
                                           markupRanges: [NSRange(location: i, length: run),
                                                          NSRange(location: close, length: run)]))
                    i = close + run
                } else {
                    i += run
                }

            case U.bang where i + 1 < to && b[i + 1] == U.leftBracket:
                // Alt text is literal: it never gets its own inline scan.
                if let span = bracketSpan(b, openBracket: i + 1, to: to) {
                    out.append(InlineToken(range: NSRange(location: i, length: span.end - i),
                                           kind: .image(destination: span.destination),
                                           markupRanges: [NSRange(location: i, length: span.textStart - i),
                                                          NSRange(location: span.textEnd, length: span.end - span.textEnd)]))
                    i = span.end
                } else {
                    i += 1
                }

            case U.leftBracket:
                if i + 1 < to, b[i + 1] == U.caret,
                   let close = index(of: U.rightBracket, in: b, from: i + 2, to: to) {
                    let label = String(utf16CodeUnits: Array(b[(i + 2)..<close]), count: close - i - 2)
                    out.append(InlineToken(range: NSRange(location: i, length: close + 1 - i),
                                           kind: .footnoteReference(label: label),
                                           markupRanges: [NSRange(location: i, length: close + 1 - i)]))
                    i = close + 1
                } else if let span = bracketSpan(b, openBracket: i, to: to) {
                    out.append(InlineToken(range: NSRange(location: i, length: span.end - i),
                                           kind: .link(destination: span.destination),
                                           markupRanges: [NSRange(location: i, length: span.textStart - i),
                                                          NSRange(location: span.textEnd, length: span.end - span.textEnd)]))
                    scanInlines(b, from: span.textStart, to: span.textEnd, depth: depth + 1, into: &out)
                    i = span.end
                } else {
                    i += 1
                }

            case U.lessThan:
                if let close = index(of: U.greaterThan, in: b, from: i + 1, to: to),
                   isAutolinkBody(b, from: i + 1, to: close) {
                    out.append(InlineToken(range: NSRange(location: i, length: close + 1 - i), kind: .autolink,
                                           markupRanges: [NSRange(location: i, length: 1),
                                                          NSRange(location: close, length: 1)]))
                    i = close + 1
                } else {
                    i += 1
                }

            case U.tilde where i + 1 < to && b[i + 1] == U.tilde:
                if let close = findRun(b, of: U.tilde, count: 2, from: i + 2, to: to) {
                    out.append(InlineToken(range: NSRange(location: i, length: close + 2 - i), kind: .strikethrough,
                                           markupRanges: [NSRange(location: i, length: 2),
                                                          NSRange(location: close, length: 2)]))
                    scanInlines(b, from: i + 2, to: close, depth: depth + 1, into: &out)
                    i = close + 2
                } else {
                    i += 2
                }

            case U.equals where i + 1 < to && b[i + 1] == U.equals:
                if let close = findRun(b, of: U.equals, count: 2, from: i + 2, to: to) {
                    out.append(InlineToken(range: NSRange(location: i, length: close + 2 - i), kind: .highlight,
                                           markupRanges: [NSRange(location: i, length: 2),
                                                          NSRange(location: close, length: 2)]))
                    scanInlines(b, from: i + 2, to: close, depth: depth + 1, into: &out)
                    i = close + 2
                } else {
                    i += 2
                }

            case U.asterisk, U.underscore:
                let run = runLength(b, of: c, from: i, limit: to)
                if let token = emphasis(b, marker: c, run: run, at: i, from: from, to: to) {
                    out.append(token.token)
                    scanInlines(b, from: token.contentStart, to: token.contentEnd, depth: depth + 1, into: &out)
                    i = token.token.range.location + token.token.range.length
                } else {
                    i += run
                }

            case U.lowerH, U.lowerW:
                if let end = bareLinkEnd(b, at: i, to: to), isWordBoundaryBefore(b, i, from) {
                    out.append(InlineToken(range: NSRange(location: i, length: end - i), kind: .autolink))
                    i = end
                } else {
                    i += 1
                }

            default:
                i += 1
            }
        }
    }

    private struct EmphasisMatch {
        var token: InlineToken
        var contentStart: Int
        var contentEnd: Int
    }

    private static func emphasis(
        _ b: UnsafeBufferPointer<unichar>, marker: unichar, run: Int, at i: Int, from: Int, to: Int
    ) -> EmphasisMatch? {
        guard i + run < to else { return nil }
        // An opener must be followed by real content.
        guard !isSpaceOrTab(b[i + run]) else { return nil }
        if marker == U.underscore, i > from, isWordCharacter(b[i - 1]) { return nil }

        let opening = run >= 2 ? 2 : 1
        guard let close = findEmphasisClose(b, marker: marker, width: opening, from: i + run, to: to) else { return nil }
        guard close > i + run else { return nil }
        let closeRun = runLength(b, of: marker, from: close, limit: to)
        let width = min(opening, closeRun)
        // Even runs nest: the leftovers of a longer run belong to the token
        // inside this one. Uneven runs leave their leftovers outside.
        let closeStart = run == closeRun ? close + closeRun - width : close
        guard closeStart >= i + run else { return nil }
        if marker == U.underscore, closeStart + width < to, isWordCharacter(b[closeStart + width]) { return nil }
        let token = InlineToken(
            range: NSRange(location: i, length: closeStart + width - i),
            kind: width == 2 ? .strong : .emphasis,
            markupRanges: [NSRange(location: i, length: width), NSRange(location: closeStart, length: width)])
        return EmphasisMatch(token: token, contentStart: i + width, contentEnd: closeStart)
    }

    private static func findEmphasisClose(
        _ b: UnsafeBufferPointer<unichar>, marker: unichar, width: Int, from: Int, to: Int
    ) -> Int? {
        var k = from
        while k < to {
            if b[k] == U.backslash { k += 2; continue }
            if b[k] == U.backtick {
                let run = runLength(b, of: U.backtick, from: k, limit: to)
                if let close = findBacktickRun(b, length: run, from: k + run, to: to) { k = close + run; continue }
                k += run
                continue
            }
            if b[k] == marker {
                let run = runLength(b, of: marker, from: k, limit: to)
                if run >= width, k > from, !isSpaceOrTab(b[k - 1]) { return k }
                k += run
                continue
            }
            k += 1
        }
        return nil
    }

    private struct BracketSpan {
        var textStart: Int
        var textEnd: Int
        var end: Int
        var destination: String
    }

    /// Matches `[text](destination)` and `[text][label]` starting at the `[`.
    private static func bracketSpan(_ b: UnsafeBufferPointer<unichar>, openBracket: Int, to: Int) -> BracketSpan? {
        var depthCount = 0
        var k = openBracket
        var closeBracket = -1
        while k < to {
            if b[k] == U.backslash { k += 2; continue }
            if b[k] == U.leftBracket { depthCount += 1 }
            if b[k] == U.rightBracket {
                depthCount -= 1
                if depthCount == 0 { closeBracket = k; break }
            }
            k += 1
        }
        guard closeBracket > openBracket, closeBracket + 1 < to else { return nil }
        let opener = b[closeBracket + 1]
        guard opener == U.leftParen || opener == U.leftBracket else { return nil }
        let closer: unichar = opener == U.leftParen ? U.rightParen : U.rightBracket
        var j = closeBracket + 2
        var nesting = 1
        while j < to {
            if b[j] == U.backslash { j += 2; continue }
            if b[j] == opener { nesting += 1 }
            if b[j] == closer {
                nesting -= 1
                if nesting == 0 { break }
            }
            j += 1
        }
        guard j < to, b[j] == closer else { return nil }
        let destination = destinationText(b, from: closeBracket + 2, to: j)
        return BracketSpan(textStart: openBracket + 1, textEnd: closeBracket, end: j + 1, destination: destination)
    }

    private static func destinationText(_ b: UnsafeBufferPointer<unichar>, from: Int, to: Int) -> String {
        var s = from
        var e = to
        while s < e, b[s] == U.space || b[s] == U.tab { s += 1 }
        while e > s, b[e - 1] == U.space || b[e - 1] == U.tab { e -= 1 }
        // A title after the destination is not part of it.
        var stop = s
        while stop < e, b[stop] != U.space, b[stop] != U.tab { stop += 1 }
        guard stop > s else { return "" }
        return String(utf16CodeUnits: Array(b[s..<stop]), count: stop - s)
    }

    private static func isAutolinkBody(_ b: UnsafeBufferPointer<unichar>, from: Int, to: Int) -> Bool {
        guard to > from else { return false }
        for k in from..<to where b[k] == U.space || b[k] == U.tab || b[k] == U.lessThan { return false }
        if hasPrefix(b, at: from, U.mailtoPrefix, to: to) { return true }
        var k = from
        while k + 2 < to {
            if b[k] == U.colon, b[k + 1] == U.slash, b[k + 2] == U.slash { return true }
            k += 1
        }
        return false
    }

    private static func bareLinkEnd(_ b: UnsafeBufferPointer<unichar>, at i: Int, to: Int) -> Int? {
        let matched = hasPrefix(b, at: i, U.httpsPrefix, to: to)
            || hasPrefix(b, at: i, U.httpPrefix, to: to)
            || hasPrefix(b, at: i, U.wwwPrefix, to: to)
        guard matched else { return nil }
        var k = i
        while k < to, !isSpaceOrTab(b[k]), b[k] != U.lessThan, b[k] != U.greaterThan, b[k] != U.pipe { k += 1 }
        while k > i, isTrailingPunctuation(b[k - 1]) { k -= 1 }
        return k > i + 4 ? k : nil
    }

    private static func isTrailingPunctuation(_ c: unichar) -> Bool {
        c == U.period || c == U.comma || c == U.semicolon || c == U.colon
            || c == U.bang || c == U.question || c == U.rightParen || c == U.rightBracket
    }

    // MARK: - Character helpers

    private static func runLength(_ b: UnsafeBufferPointer<unichar>, of c: unichar, from: Int, limit: Int) -> Int {
        var k = from
        while k < limit, b[k] == c { k += 1 }
        return k - from
    }

    private static func findRun(_ b: UnsafeBufferPointer<unichar>, of c: unichar, count: Int, from: Int, to: Int) -> Int? {
        var k = from
        while k < to {
            if b[k] == U.backslash { k += 2; continue }
            if b[k] == c, runLength(b, of: c, from: k, limit: to) >= count { return k }
            k += 1
        }
        return nil
    }

    private static func findBacktickRun(_ b: UnsafeBufferPointer<unichar>, length: Int, from: Int, to: Int) -> Int? {
        var k = from
        while k < to {
            if b[k] == U.backtick {
                let run = runLength(b, of: U.backtick, from: k, limit: to)
                if run == length { return k }
                k += run
                continue
            }
            k += 1
        }
        return nil
    }

    private static func index(of c: unichar, in b: UnsafeBufferPointer<unichar>, from: Int, to: Int) -> Int? {
        var k = from
        while k < to {
            if b[k] == U.backslash { k += 2; continue }
            if b[k] == c { return k }
            k += 1
        }
        return nil
    }

    private static func contains(_ b: UnsafeBufferPointer<unichar>, _ c: unichar, from: Int, to: Int) -> Bool {
        index(of: c, in: b, from: from, to: to) != nil
    }

    private static func hasPrefix(_ b: UnsafeBufferPointer<unichar>, at i: Int, _ prefix: [unichar], to: Int) -> Bool {
        guard i + prefix.count <= to else { return false }
        for (offset, unit) in prefix.enumerated() where b[i + offset] != unit { return false }
        return true
    }

    private static func isSpaceOrTab(_ c: unichar) -> Bool { c == U.space || c == U.tab }

    private static func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }

    private static func isWordCharacter(_ c: unichar) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c >= 0x80
    }

    private static func isWordBoundaryBefore(_ b: UnsafeBufferPointer<unichar>, _ i: Int, _ from: Int) -> Bool {
        i == from || !isWordCharacter(b[i - 1])
    }
}

/// UTF-16 codes the scanner compares against.
enum U {
    static let tab: unichar = 0x09
    static let newline: unichar = 0x0A
    static let carriageReturn: unichar = 0x0D
    static let space: unichar = 0x20
    static let bang: unichar = 0x21
    static let hash: unichar = 0x23
    static let asterisk: unichar = 0x2A
    static let plus: unichar = 0x2B
    static let comma: unichar = 0x2C
    static let hyphen: unichar = 0x2D
    static let period: unichar = 0x2E
    static let slash: unichar = 0x2F
    static let colon: unichar = 0x3A
    static let semicolon: unichar = 0x3B
    static let lessThan: unichar = 0x3C
    static let equals: unichar = 0x3D
    static let greaterThan: unichar = 0x3E
    static let question: unichar = 0x3F
    static let upperX: unichar = 0x58
    static let leftBracket: unichar = 0x5B
    static let backslash: unichar = 0x5C
    static let rightBracket: unichar = 0x5D
    static let caret: unichar = 0x5E
    static let underscore: unichar = 0x5F
    static let backtick: unichar = 0x60
    static let lowerH: unichar = 0x68
    static let lowerW: unichar = 0x77
    static let lowerX: unichar = 0x78
    static let leftParen: unichar = 0x28
    static let rightParen: unichar = 0x29
    static let pipe: unichar = 0x7C
    static let tilde: unichar = 0x7E
    static let lineSeparator: unichar = 0x2028
    static let paragraphSeparator: unichar = 0x2029

    static let httpPrefix = Array("http://".utf16)
    static let httpsPrefix = Array("https://".utf16)
    static let wwwPrefix = Array("www.".utf16)
    static let mailtoPrefix = Array("mailto:".utf16)
}

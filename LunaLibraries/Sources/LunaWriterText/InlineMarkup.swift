import Foundation

/// Turns a scanned range back into what the reader sees: the text without its
/// syntax characters, with runs of whitespace collapsed.
enum InlineMarkup {
    static func plainText(of range: NSRange, in text: NSString, inlines: [InlineToken]) -> String {
        guard range.length > 0 else { return "" }
        var cuts: [NSRange] = []
        for token in inlines {
            guard NSIntersectionRange(token.range, range).length > 0 || token.range.length == 0 else { continue }
            switch token.kind {
            case .hardBreak:
                cuts.append(token.range)
            default:
                cuts.append(contentsOf: token.markupRanges)
            }
        }
        cuts.sort { $0.location < $1.location }

        var out = ""
        out.reserveCapacity(range.length)
        var cursor = range.location
        let end = range.location + range.length
        for cut in cuts {
            let start = max(cut.location, range.location)
            let stop = min(cut.location + cut.length, end)
            guard stop > start else { continue }
            if start > cursor { out += text.substring(with: NSRange(location: cursor, length: start - cursor)) }
            cursor = max(cursor, stop)
        }
        if cursor < end { out += text.substring(with: NSRange(location: cursor, length: end - cursor)) }
        return collapseWhitespace(out)
    }

    static func collapseWhitespace(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                if !out.isEmpty { pendingSpace = true }
                continue
            }
            if pendingSpace { out.append(" ") }
            pendingSpace = false
            out.append(character)
        }
        return out
    }
}

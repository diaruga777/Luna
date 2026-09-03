//
//  EditorMarkdownActions.swift
//  LunaWriterEditor
//

import Foundation
import LunaWriterText

/// The two toolbar commands `MarkdownEditingCommands` does not carry yet.
///
/// Both answer edits ordered from the end of the text backwards, the same
/// contract the rest of the commands keep, so they apply through the same
/// undo manager without moving any offsets.
public enum EditorMarkdownActions {

    public static let quoteMarker = "> "

    /// Puts "> " in front of every line the selection touches, or takes it
    /// off every line that already has it.
    public static func toggleQuote(_ range: NSRange, in text: NSString) -> [TextEdit] {
        let lines = lineRanges(covering: range, in: text)
        guard !lines.isEmpty else { return [] }
        let allQuoted = lines.allSatisfy { text.substring(with: $0).hasPrefix(quoteMarker) }
        return lines.reversed().map { line in
            if allQuoted {
                return TextEdit(
                    range: NSRange(location: line.location, length: (quoteMarker as NSString).length),
                    replacement: "")
            }
            return TextEdit(range: NSRange(location: line.location, length: 0), replacement: quoteMarker)
        }
    }

    /// Wraps the selection as a link and leaves the destination empty, which
    /// is where the caret goes.
    public static func insertLink(_ range: NSRange, in text: NSString) -> [TextEdit] {
        let title = range.length > 0 ? text.substring(with: range) : ""
        return [TextEdit(range: range, replacement: "[\(title)]()")]
    }

    /// Where the caret goes after `insertLink`: inside the parentheses.
    public static func linkDestinationCaret(after range: NSRange) -> Int {
        range.location + 3 + range.length
    }

    private static func lineRanges(covering range: NSRange, in text: NSString) -> [NSRange] {
        guard text.length > 0 else { return [] }
        var out: [NSRange] = []
        var location = min(range.location, text.length - 1)
        let end = min(max(NSMaxRange(range), range.location + 1), text.length)
        while location < end {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            out.append(line)
            location = max(NSMaxRange(line), location + 1)
        }
        return out
    }
}

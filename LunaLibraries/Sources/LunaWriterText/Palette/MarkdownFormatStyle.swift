import Foundation

/// The edits one formatting command makes, and where the caret goes after.
public struct FormatApplication: Equatable, Sendable {
    /// Ordered from the end of the text backwards, the `MarkdownEditingCommands` contract.
    public var edits: [TextEdit]
    /// The caret's offset in the text after every edit is applied.
    public var caret: Int

    public init(edits: [TextEdit], caret: Int) {
        self.edits = edits
        self.caret = caret
    }
}

/// Every Markdown style the palette's formatting rows apply.
///
/// An inline style types its opening and closing marks and leaves the caret
/// between them. A line style marks the paragraph the caret is in. A block
/// style stands on lines of its own.
public enum MarkdownFormatStyle: String, CaseIterable, Sendable {
    case bold, italic, boldItalic, strikethrough, highlight, underline, inlineCode, link, image, footnote
    case heading1, heading2, heading3, heading4, heading5, heading6
    case quote, bulletList, numberedList, taskList
    case codeBlock, divider

    public enum Placement: Equatable, Sendable {
        case inline
        case line
        case block
    }

    public var placement: Placement {
        switch self {
        case .bold, .italic, .boldItalic, .strikethrough, .highlight, .underline, .inlineCode, .link, .image,
             .footnote:
            return .inline
        case .heading1, .heading2, .heading3, .heading4, .heading5, .heading6, .quote, .bulletList,
             .numberedList, .taskList:
            return .line
        case .codeBlock, .divider:
            return .block
        }
    }

    /// The opening mark, as the writer would type it.
    public var prefix: String {
        switch self {
        case .bold: return "**"
        case .italic: return "*"
        case .boldItalic: return "***"
        case .strikethrough: return "~~"
        case .highlight: return "=="
        case .underline: return "<u>"
        case .inlineCode: return "`"
        case .link: return "["
        case .image: return "!["
        case .footnote: return "[^"
        case .heading1: return "# "
        case .heading2: return "## "
        case .heading3: return "### "
        case .heading4: return "#### "
        case .heading5: return "##### "
        case .heading6: return "###### "
        case .quote: return "> "
        case .bulletList: return "- "
        case .numberedList: return "1. "
        case .taskList: return "- [ ] "
        case .codeBlock: return "```"
        case .divider: return "---"
        }
    }

    /// The closing mark. Empty for a line or block style with none.
    public var suffix: String {
        switch self {
        case .bold: return "**"
        case .italic: return "*"
        case .boldItalic: return "***"
        case .strikethrough: return "~~"
        case .highlight: return "=="
        case .underline: return "</u>"
        case .inlineCode: return "`"
        case .link, .image: return "]()"
        case .footnote: return "]"
        case .codeBlock: return "```"
        default: return ""
        }
    }

    public var headingLevel: Int? {
        switch self {
        case .heading1: return 1
        case .heading2: return 2
        case .heading3: return 3
        case .heading4: return 4
        case .heading5: return 5
        case .heading6: return 6
        default: return nil
        }
    }

    /// What a row shows for the style: the marks around a sample word.
    public func preview(sample: String) -> String {
        switch placement {
        case .inline: return prefix + sample + suffix
        case .line: return prefix + sample
        case .block: return self == .divider ? prefix : prefix + "\n" + sample + "\n" + suffix
        }
    }

    // MARK: - Applying

    /// The edits that apply this style at `caret` in `text`, with nothing
    /// selected. An inline style opens an empty pair; a line style marks the
    /// caret's paragraph and keeps the caret on its own text; a block style
    /// opens on a fresh line.
    public func application(at caret: Int, in text: NSString) -> FormatApplication {
        let caret = min(max(0, caret), text.length)
        switch placement {
        case .inline:
            return FormatApplication(
                edits: [
                    TextEdit(range: NSRange(location: caret, length: 0), replacement: suffix),
                    TextEdit(range: NSRange(location: caret, length: 0), replacement: prefix),
                ],
                caret: caret + (prefix as NSString).length)
        case .line:
            return lineApplication(at: caret, in: text)
        case .block:
            return blockApplication(at: caret, in: text)
        }
    }

    private func lineApplication(at caret: Int, in text: NSString) -> FormatApplication {
        let edits: [TextEdit]
        if let level = headingLevel {
            edits = MarkdownEditingCommands.setHeading(level, paragraphAt: caret, in: text)
        } else {
            edits = Self.lineMarkerEdits(prefix, at: caret, in: text)
        }
        return FormatApplication(edits: edits, caret: Self.shifted(caret, by: edits))
    }

    /// Puts `marker` after the line's indentation, replacing a list or quote
    /// marker already there so two styles never stack.
    private static func lineMarkerEdits(_ marker: String, at caret: Int, in text: NSString) -> [TextEdit] {
        let line = MarkdownEditingCommands.lineRange(at: caret, in: text)
        var start = line.location
        while start < NSMaxRange(line), Self.isSpaceOrTab(text.character(at: start)) { start += 1 }
        var end = start
        let lineEnd = NSMaxRange(line)
        // "> ", "- ", "* ", "+ ", "1. ", "- [ ] " and their spacing.
        if end < lineEnd, text.character(at: end) == 0x3E {
            end += 1
            if end < lineEnd, text.character(at: end) == 0x20 { end += 1 }
        } else if end < lineEnd, [0x2D, 0x2A, 0x2B].contains(text.character(at: end)),
                  end + 1 < lineEnd, text.character(at: end + 1) == 0x20 {
            end += 2
            if end + 2 < lineEnd, text.character(at: end) == 0x5B, text.character(at: end + 2) == 0x5D {
                end += 3
                if end < lineEnd, text.character(at: end) == 0x20 { end += 1 }
            }
        } else {
            var digits = end
            while digits < lineEnd, (0x30...0x39).contains(text.character(at: digits)) { digits += 1 }
            if digits > end, digits + 1 < lineEnd, text.character(at: digits) == 0x2E,
               text.character(at: digits + 1) == 0x20 {
                end = digits + 2
            }
        }
        let existing = text.substring(with: NSRange(location: start, length: end - start))
        guard existing != marker else { return [] }
        return [TextEdit(range: NSRange(location: start, length: end - start), replacement: marker)]
    }

    private func blockApplication(at caret: Int, in text: NSString) -> FormatApplication {
        let atLineStart = caret == 0 || Self.isLineBreak(text.character(at: caret - 1))
        let atLineEnd = caret == text.length || Self.isLineBreak(text.character(at: caret))
        let opening = (atLineStart ? "" : "\n") + prefix + "\n"
        let closing = self == .divider ? "" : "\n" + suffix + (atLineEnd ? "" : "\n")
        let insertion = opening + closing
        return FormatApplication(
            edits: [TextEdit(range: NSRange(location: caret, length: 0), replacement: insertion)],
            caret: caret + (opening as NSString).length)
    }

    /// Where `caret` lands after `edits` (each at or before it) change lengths.
    private static func shifted(_ caret: Int, by edits: [TextEdit]) -> Int {
        var result = caret
        for edit in edits where edit.range.location <= caret {
            let delta = (edit.replacement as NSString).length - edit.range.length
            if NSMaxRange(edit.range) <= caret {
                result += delta
            } else {
                result = edit.range.location + (edit.replacement as NSString).length
            }
        }
        return max(0, result)
    }

    private static func isSpaceOrTab(_ unit: unichar) -> Bool { unit == 0x20 || unit == 0x09 }
    private static func isLineBreak(_ unit: unichar) -> Bool { unit == 0x0A || unit == 0x0D }
}

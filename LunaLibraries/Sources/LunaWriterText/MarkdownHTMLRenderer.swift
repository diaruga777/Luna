import Foundation

/// Renders a whole document to HTML for export and for the PDF printer.
/// It reads the same `MarkdownDocumentModel` the editor styles, so what is
/// exported is what the writer was shown.
public struct MarkdownHTMLRenderer {

    public struct Options: Sendable {
        /// False emits the body fragment only.
        public var includeDocumentShell: Bool
        public var title: String?
        public var stylesheet: String?
        /// Resolves a relative image path in the exported page.
        public var imageBaseURL: URL?

        public init(includeDocumentShell: Bool = true, title: String? = nil, stylesheet: String? = nil, imageBaseURL: URL? = nil) {
            self.includeDocumentShell = includeDocumentShell
            self.title = title
            self.stylesheet = stylesheet
            self.imageBaseURL = imageBaseURL
        }
    }

    private let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    public func render(markdown: NSString) -> String {
        render(MarkdownDocumentModel(text: markdown))
    }

    public func render(_ model: MarkdownDocumentModel) -> String {
        var writer = Writer(options: options, text: model.text)
        for scan in model.allLineScans() { writer.take(scan) }
        let body = writer.finish()
        guard options.includeDocumentShell else { return body }
        var head = "<meta charset=\"utf-8\">"
        if let title = options.title { head += "<title>\(HTML.escape(title))</title>" }
        if let stylesheet = options.stylesheet { head += "<style>\(stylesheet)</style>" }
        return "<!DOCTYPE html>\n<html>\n<head>\(head)</head>\n<body>\n\(body)</body>\n</html>\n"
    }

    // MARK: - Block writer

    private struct Writer {
        let options: Options
        let text: NSString
        var out = ""
        var listStack: [(ordered: Bool, indent: Int)] = []
        var itemOpen = false
        var quoteDepth = 0
        var paragraphOpen = false
        var inCode = false
        var table: TableState?
        var footnotes: [(label: String, html: String)] = []

        struct TableState {
            var alignments: [String] = []
            var inHeader = true
            var headerCells: [[String]] = []
            var bodyRows: [[String]] = []
        }

        init(options: Options, text: NSString) {
            self.options = options
            self.text = text
        }

        mutating func take(_ scan: LineScan) {
            switch scan.block.kind {
            case .fenceDelimiter:
                if inCode {
                    out += "</code></pre>\n"
                    inCode = false
                } else {
                    closeBlocks(keepList: false)
                    let language = scan.stateAfter.fenceLanguage
                    let attribute = language.map { " class=\"language-\(HTML.escape($0))\"" } ?? ""
                    out += "<pre><code\(attribute)>"
                    inCode = true
                }

            case .fencedCode:
                out += HTML.escape(text.substring(with: scan.block.contentRange), unescapeMarkdown: false) + "\n"

            case .blank:
                closeParagraph()
                closeQuote()
                closeTable()

            case .heading(let level):
                closeBlocks(keepList: false)
                let inner = HTML.inline(scan, in: scan.block.contentRange, text: text, options: options)
                out += "<h\(level)>\(inner)</h\(level)>\n"

            case .thematicBreak:
                closeBlocks(keepList: false)
                out += "<hr>\n"

            case .paragraph:
                closeTable()
                let inner = HTML.inline(scan, in: scan.block.contentRange, text: text, options: options)
                if paragraphOpen {
                    out += hasHardBreak(scan) ? "<br>\n" : "\n"
                } else {
                    closeList()
                    out += "<p>"
                    paragraphOpen = true
                }
                out += inner

            case .blockquote(let depth):
                closeTable()
                closeList()
                if depth != quoteDepth { closeParagraph() }
                while quoteDepth < depth { out += "<blockquote>\n"; quoteDepth += 1 }
                while quoteDepth > depth { out += "</blockquote>\n"; quoteDepth -= 1 }
                let inner = HTML.inline(scan, in: scan.block.contentRange, text: text, options: options)
                if paragraphOpen { out += hasHardBreak(scan) ? "<br>\n" : "\n" } else { out += "<p>"; paragraphOpen = true }
                out += inner

            case .listItem(let ordered, let indent, let task):
                closeTable()
                closeParagraph()
                openList(ordered: ordered, indent: indent)
                if itemOpen { out += "</li>\n" }
                out += "<li>"
                itemOpen = true
                if let task {
                    out += "<input type=\"checkbox\" disabled\(task == .checked ? " checked" : "")> "
                }
                out += HTML.inline(scan, in: scan.block.contentRange, text: text, options: options)

            case .tableRow(let isHeader):
                closeParagraph()
                closeList()
                if table == nil { table = TableState() }
                let cells = HTML.cells(scan, text: text, options: options)
                if isHeader, table?.bodyRows.isEmpty == true, table?.headerCells.isEmpty == true {
                    table?.headerCells.append(cells)
                } else {
                    table?.bodyRows.append(cells)
                }

            case .tableDelimiter:
                let row = text.substring(with: scan.block.markupRanges.first ?? scan.block.contentRange)
                let columns = HTML.alignments(row)
                table?.alignments = columns
                table?.inHeader = false

            case .footnoteDefinition(let label):
                closeBlocks(keepList: false)
                footnotes.append((label, HTML.inline(scan, in: scan.block.contentRange, text: text, options: options)))
            }
        }

        mutating func finish() -> String {
            if inCode { out += "</code></pre>\n"; inCode = false }
            closeBlocks(keepList: false)
            if !footnotes.isEmpty {
                out += "<section class=\"footnotes\">\n<ol>\n"
                for note in footnotes {
                    out += "<li id=\"fn-\(HTML.escape(note.label))\">\(note.html)</li>\n"
                }
                out += "</ol>\n</section>\n"
            }
            return out
        }

        private func hasHardBreak(_ scan: LineScan) -> Bool {
            scan.inlines.contains { $0.kind == .hardBreak }
        }

        private mutating func openList(ordered: Bool, indent: Int) {
            while let top = listStack.last, indent < top.indent {
                if itemOpen { out += "</li>\n"; itemOpen = false }
                out += top.ordered ? "</ol>\n" : "</ul>\n"
                listStack.removeLast()
                itemOpen = !listStack.isEmpty
            }
            if let top = listStack.last, top.indent == indent, top.ordered != ordered {
                if itemOpen { out += "</li>\n"; itemOpen = false }
                out += top.ordered ? "</ol>\n" : "</ul>\n"
                listStack.removeLast()
                itemOpen = !listStack.isEmpty
            }
            if listStack.isEmpty || indent > listStack[listStack.count - 1].indent {
                out += ordered ? "<ol>\n" : "<ul>\n"
                listStack.append((ordered, indent))
                itemOpen = false
            }
        }

        private mutating func closeList() {
            while let top = listStack.popLast() {
                if itemOpen { out += "</li>\n"; itemOpen = false }
                out += top.ordered ? "</ol>\n" : "</ul>\n"
                itemOpen = !listStack.isEmpty
            }
            itemOpen = false
        }

        private mutating func closeParagraph() {
            guard paragraphOpen else { return }
            out += "</p>\n"
            paragraphOpen = false
        }

        private mutating func closeQuote() {
            closeParagraph()
            while quoteDepth > 0 { out += "</blockquote>\n"; quoteDepth -= 1 }
        }

        private mutating func closeTable() {
            guard let state = table else { return }
            table = nil
            out += "<table>\n"
            if let header = state.headerCells.first {
                out += "<thead>\n<tr>"
                for (index, cell) in header.enumerated() { out += "<th\(HTML.alignAttribute(state.alignments, index))>\(cell)</th>" }
                out += "</tr>\n</thead>\n"
            }
            if !state.bodyRows.isEmpty {
                out += "<tbody>\n"
                for row in state.bodyRows {
                    out += "<tr>"
                    for (index, cell) in row.enumerated() { out += "<td\(HTML.alignAttribute(state.alignments, index))>\(cell)</td>" }
                    out += "</tr>\n"
                }
                out += "</tbody>\n"
            }
            out += "</table>\n"
        }

        private mutating func closeBlocks(keepList: Bool) {
            closeTable()
            closeParagraph()
            if !keepList { closeList() }
            closeQuote()
        }
    }
}

/// The HTML text helpers. Kept apart so the block writer reads as structure.
enum HTML {
    static func escape(_ text: String, unescapeMarkdown: Bool = true) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            index += 1
            // A backslash escape belongs to Markdown, not to the output.
            if unescapeMarkdown, character == "\\", index < characters.count, characters[index].isASCII,
               characters[index].isPunctuation || characters[index].isSymbol {
                continue
            }
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }

    static func attribute(_ text: String, base: URL?) -> String {
        var value = text
        if let base, URL(string: text)?.scheme == nil, let resolved = URL(string: text, relativeTo: base)?.absoluteString {
            value = resolved
        }
        return escape(value, unescapeMarkdown: false)
    }

    /// Renders the inline spans inside `range` as nested HTML.
    static func inline(_ scan: LineScan, in range: NSRange, text: NSString, options: MarkdownHTMLRenderer.Options) -> String {
        var index = 0
        let tokens = scan.inlines.filter { NSIntersectionRange($0.range, range).length > 0 || $0.range.length == 0 }
        return render(range: range, tokens: tokens, index: &index, text: text, options: options)
    }

    static func cells(_ scan: LineScan, text: NSString, options: MarkdownHTMLRenderer.Options) -> [String] {
        let pipes = scan.block.markupRanges
        var out: [String] = []
        let content = scan.block.contentRange
        var start = content.location
        for pipe in pipes {
            if pipe.location > start || out.isEmpty || pipe.location == start {
                let cell = NSRange(location: start, length: max(0, pipe.location - start))
                out.append(trimmedInline(scan, in: cell, text: text, options: options))
            }
            start = pipe.location + pipe.length
        }
        let tail = NSRange(location: start, length: max(0, NSMaxRange(content) - start))
        out.append(trimmedInline(scan, in: tail, text: text, options: options))
        // A row written with outer pipes opens and closes with an empty cell.
        if out.first?.isEmpty == true { out.removeFirst() }
        if out.last?.isEmpty == true { out.removeLast() }
        return out
    }

    private static func trimmedInline(_ scan: LineScan, in range: NSRange, text: NSString, options: MarkdownHTMLRenderer.Options) -> String {
        var trimmed = range
        while trimmed.length > 0, isSpace(text.character(at: trimmed.location)) {
            trimmed.location += 1
            trimmed.length -= 1
        }
        while trimmed.length > 0, isSpace(text.character(at: NSMaxRange(trimmed) - 1)) { trimmed.length -= 1 }
        guard trimmed.length > 0 else { return "" }
        return inline(scan, in: trimmed, text: text, options: options)
    }

    private static func isSpace(_ unit: unichar) -> Bool { unit == 0x20 || unit == 0x09 }

    static func alignments(_ delimiter: String) -> [String] {
        delimiter.split(separator: "|", omittingEmptySubsequences: true).map { column in
            let piece = column.trimmingCharacters(in: .whitespaces)
            let left = piece.hasPrefix(":")
            let right = piece.hasSuffix(":")
            if left, right { return "center" }
            if right { return "right" }
            if left { return "left" }
            return ""
        }
    }

    static func alignAttribute(_ alignments: [String], _ index: Int) -> String {
        guard index < alignments.count, !alignments[index].isEmpty else { return "" }
        return " style=\"text-align: \(alignments[index])\""
    }

    private static func render(
        range: NSRange, tokens: [InlineToken], index: inout Int, text: NSString, options: MarkdownHTMLRenderer.Options
    ) -> String {
        var out = ""
        var cursor = range.location
        let end = NSMaxRange(range)
        while index < tokens.count {
            let token = tokens[index]
            guard token.range.location >= range.location, NSMaxRange(token.range) <= end else { break }
            index += 1
            if token.range.location > cursor {
                out += escape(text.substring(with: NSRange(location: cursor, length: token.range.location - cursor)))
            }
            out += tag(token, tokens: tokens, index: &index, text: text, options: options)
            cursor = max(cursor, NSMaxRange(token.range))
        }
        if cursor < end {
            out += escape(text.substring(with: NSRange(location: cursor, length: end - cursor)))
        }
        return out
    }

    private static func tag(
        _ token: InlineToken, tokens: [InlineToken], index: inout Int, text: NSString, options: MarkdownHTMLRenderer.Options
    ) -> String {
        func children() -> String {
            render(range: token.contentRange, tokens: tokens, index: &index, text: text, options: options)
        }
        switch token.kind {
        case .emphasis: return "<em>\(children())</em>"
        case .strong: return "<strong>\(children())</strong>"
        case .strikethrough: return "<del>\(children())</del>"
        case .highlight: return "<mark>\(children())</mark>"
        case .code: return "<code>\(escape(text.substring(with: token.contentRange), unescapeMarkdown: false))</code>"
        case .hardBreak: return "<br>"
        case .link(let destination):
            return "<a href=\"\(attribute(destination, base: nil))\">\(children())</a>"
        case .image(let destination):
            let alt = escape(text.substring(with: token.contentRange))
            return "<img src=\"\(attribute(destination, base: options.imageBaseURL))\" alt=\"\(alt)\">"
        case .autolink:
            let target = text.substring(with: token.contentRange)
            let href = target.contains("://") || target.hasPrefix("mailto:") ? target : "https://" + target
            return "<a href=\"\(attribute(href, base: nil))\">\(escape(target))</a>"
        case .footnoteReference(let label):
            let safe = escape(label)
            return "<sup class=\"footnote-ref\"><a href=\"#fn-\(safe)\">\(safe)</a></sup>"
        }
    }
}

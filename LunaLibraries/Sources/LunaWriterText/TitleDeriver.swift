import Foundation

/// Names a sheet from its own text. The library re-derives the title on every
/// save, so a document is never named by hand.
///
/// A document with nothing to name it answers nil. This tier holds no strings:
/// the caller supplies the word an untitled sheet shows.
public enum TitleDeriver {

    public struct DerivedTitle: Equatable, Sendable {
        /// The title with its Markdown taken out.
        public var text: String
        /// The whole line the title came from, terminator included.
        public var lineRange: NSRange
        public var isHeading: Bool

        public init(text: String, lineRange: NSRange, isHeading: Bool) {
            self.text = text
            self.lineRange = lineRange
            self.isHeading = isHeading
        }
    }

    /// The first heading, else the first line with words in it, else nil.
    public static func derive(from model: MarkdownDocumentModel) -> DerivedTitle? {
        var firstLine: DerivedTitle?
        for index in 0..<model.lineCount {
            let scan = model.lineScan(at: index)
            let plain = InlineMarkup.plainText(of: scan.block.contentRange, in: model.text, inlines: scan.inlines)
            if case .heading = scan.block.kind, !plain.isEmpty {
                return DerivedTitle(text: plain, lineRange: scan.block.lineRange, isHeading: true)
            }
            if firstLine == nil, !plain.isEmpty, carriesTitle(scan.block.kind) {
                firstLine = DerivedTitle(text: plain, lineRange: scan.block.lineRange, isHeading: false)
            }
        }
        return firstLine
    }

    public static func derive(from text: NSString) -> DerivedTitle? {
        derive(from: MarkdownDocumentModel(text: text))
    }

    /// The first characters of the body after the title, for a list row.
    public static func snippet(of model: MarkdownDocumentModel, after title: DerivedTitle?, limit: Int = 160) -> String {
        var out = ""
        let titleLine = title?.lineRange.location
        for index in 0..<model.lineCount {
            let scan = model.lineScan(at: index)
            guard scan.block.lineRange.location != titleLine else { continue }
            guard carriesSnippet(scan.block.kind) else { continue }
            let plain = InlineMarkup.plainText(of: scan.block.contentRange, in: model.text, inlines: scan.inlines)
            guard !plain.isEmpty else { continue }
            if !out.isEmpty { out += " " }
            out += plain
            if out.count >= limit { break }
        }
        return trim(out, to: limit)
    }

    public static func snippet(of text: NSString, after title: DerivedTitle?, limit: Int = 160) -> String {
        snippet(of: MarkdownDocumentModel(text: text), after: title, limit: limit)
    }

    /// Cuts at a word boundary and never mid-word.
    static func trim(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.index(text.startIndex, offsetBy: limit)
        if let space = text[..<cut].lastIndex(where: { $0 == " " }) {
            return String(text[..<space])
        }
        return String(text[..<cut])
    }

    private static func carriesTitle(_ kind: BlockKind) -> Bool {
        switch kind {
        case .blank, .fenceDelimiter, .thematicBreak, .tableDelimiter, .fencedCode: return false
        default: return true
        }
    }

    private static func carriesSnippet(_ kind: BlockKind) -> Bool {
        switch kind {
        case .blank, .fenceDelimiter, .thematicBreak, .tableDelimiter, .heading: return false
        default: return true
        }
    }
}

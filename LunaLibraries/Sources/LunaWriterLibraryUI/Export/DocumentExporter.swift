import UIKit
import LunaDesignSystem
import LunaModels
import LunaWriterModels
import LunaWriterText

/// The four shapes a sheet can leave the app in.
public enum DocumentExportFormat: String, CaseIterable {
    case markdown, plainText, html, pdf

    public var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .plainText: return "txt"
        case .html: return "html"
        case .pdf: return "pdf"
        }
    }

    public var displayName: String {
        switch self {
        case .markdown: return L10n.string("WriterLibrary_export_formatMarkdown")
        case .plainText: return L10n.string("WriterLibrary_export_formatPlainText")
        case .html: return L10n.string("WriterLibrary_export_formatHTML")
        case .pdf: return L10n.string("WriterLibrary_export_formatPDF")
        }
    }
}

/// Turns a sheet's Markdown text into Markdown, plain text, HTML or PDF, and
/// hands the result to the system share sheet.
public enum DocumentExporter {

    /// The night/paper stylesheet the HTML and PDF exports share.
    private static let stylesheet = """
    body { background: #0b0b0f; color: #f2f2f4; font: -apple-system-body; \
    max-width: 40em; margin: 2em auto; padding: 0 1em; line-height: 1.5; }
    h1, h2, h3 { color: #ffffff; }
    code, pre { background: #1c1c22; padding: 0.15em 0.35em; border-radius: 4px; }
    blockquote { border-left: 3px solid #4d4d57; margin-left: 0; padding-left: 1em; color: #c7c7cf; }
    a { color: #8ea2ff; }
    """

    public static func data(for text: String, title: String, format: DocumentExportFormat) -> Data {
        switch format {
        case .markdown:
            return Data(text.utf8)
        case .plainText:
            return Data(plainText(from: text).utf8)
        case .html:
            return Data(html(from: text, title: title).utf8)
        case .pdf:
            return pdfData(fromHTML: html(from: text, title: title))
        }
    }

    /// Strips Markdown syntax characters, keeping their content, using the
    /// scanner's own markup ranges rather than a second parser.
    public static func plainText(from markdown: String) -> String {
        let model = MarkdownDocumentModel(text: markdown)
        let text = model.text
        var lines: [String] = []
        for index in 0..<model.lineCount {
            let scan = model.lineScan(at: index)
            switch scan.block.kind {
            case .blank:
                lines.append("")
                continue
            case .fenceDelimiter, .thematicBreak, .tableDelimiter:
                continue
            default:
                break
            }
            var removals = scan.block.markupRanges
            removals += scan.inlines.flatMap(\.markupRanges)
            lines.append(strip(removals, from: scan.block.lineRange, in: text))
        }
        return lines.joined(separator: "\n")
    }

    private static func strip(_ removals: [NSRange], from lineRange: NSRange, in text: NSString) -> String {
        let sorted = removals.sorted { $0.location < $1.location }
        var result = ""
        var cursor = lineRange.location
        let end = lineRange.location + lineRange.length
        for removal in sorted {
            guard removal.location >= cursor, removal.location + removal.length <= end else { continue }
            if removal.location > cursor {
                result += text.substring(with: NSRange(location: cursor, length: removal.location - cursor))
            }
            cursor = removal.location + removal.length
        }
        if cursor < end {
            result += text.substring(with: NSRange(location: cursor, length: end - cursor))
        }
        return result.trimmingCharacters(in: .newlines)
    }

    public static func html(from markdown: String, title: String) -> String {
        let renderer = MarkdownHTMLRenderer(options: .init(
            includeDocumentShell: true, title: title, stylesheet: stylesheet))
        return renderer.render(markdown: markdown as NSString)
    }

    /// US Letter at 72dpi with a half-inch margin, rendered through the same
    /// markup formatter `UIPrintInteractionController` uses.
    public static func pdfData(
        fromHTML html: String, pageSize: CGSize = CGSize(width: 612, height: 792)
    ) -> Data {
        let formatter = UIMarkupTextPrintFormatter(markupText: html)
        let pageBounds = CGRect(origin: .zero, size: pageSize)
        let printable = pageBounds.insetBy(dx: 36, dy: 36)
        let renderer = PDFPageRenderer(pageBounds: pageBounds, printableRect: printable)
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        let pdfRenderer = UIGraphicsPDFRenderer(bounds: pageBounds)
        return pdfRenderer.pdfData { context in
            for page in 0..<max(1, renderer.numberOfPages) {
                context.beginPage()
                renderer.drawPage(at: page, in: context.pdfContextBounds)
            }
        }
    }

    /// Writes the export to a temp file (so the share sheet offers the real
    /// filename and extension) and presents it.
    public static func exportAndPresent(
        document: WriterDocument, text: String, format: DocumentExportFormat,
        from presenter: UIViewController, anchor: LunaShareSheetAnchor?
    ) {
        let payload = data(for: text, title: document.title, format: format)
        let name = (document.title.isEmpty ? L10n.string("Common_untitled") : document.title)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name)
            .appendingPathExtension(format.fileExtension)
        do {
            try payload.write(to: url, options: .atomic)
        } catch {
            return
        }
        LunaShareSheet.present(items: [url], from: presenter, anchor: anchor)
    }
}

/// Fixed page geometry for `UIPrintPageRenderer`, whose `paperRect` and
/// `printableRect` are read-only on the base class.
private final class PDFPageRenderer: UIPrintPageRenderer {
    private let fixedPaperRect: CGRect
    private let fixedPrintableRect: CGRect

    init(pageBounds: CGRect, printableRect: CGRect) {
        self.fixedPaperRect = pageBounds
        self.fixedPrintableRect = printableRect
        super.init()
    }

    override var paperRect: CGRect { fixedPaperRect }
    override var printableRect: CGRect { fixedPrintableRect }
}

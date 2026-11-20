//
//  DocumentParser.swift
//  Luna
//

import LunaModels
import Foundation
import PDFKit
import Vision

/// Turns an imported document file into `ArticleContent`. PDF text via PDFKit and optional Vision OCR,
/// RTF via attributed string, EPUB and `.docx` via their own readers over
/// `ZipArchiveReader`, HTML through the markup extractor, plain text and
/// Markdown via the pure parsers below. Returns nil when nothing readable can be
/// extracted.
///
/// **`title` is a fallback for the container formats.** It is the shared
/// file's name, which for a book is a distribution artifact
/// ("pg84-images-3"); an EPUB or `.docx` that names itself in its own
/// metadata wins, and `saveContent` carries that title back onto the save
/// row.
public enum DocumentParser {

    /// The formats `parse` has a specific reader for. Parsed once, from the
    /// raw extension string, instead of switching on that string twice over
    /// two separately hand-kept case lists.
    enum ReadableDocumentFormat: String, CaseIterable {
        case pdf, epub, docx, rtf, html, htm, xhtml, md, markdown, txt, text

        /// Case-insensitive; nil for an extension `parse` has no specific reader
        /// for — which still parses (as plain text), it just isn't one of these.
        init?(extension rawExtension: String) {
            self.init(rawValue: rawExtension.lowercased())
        }
    }

    /// Every extension that can be read, which is also what
    /// `ShareAttachmentRouter` offers to accept — the two lists exist for
    /// different callers (one takes files, one takes UTTypes) and
    /// `EbookDocumentImportTests` pins them to each other. Derived from
    /// `ReadableDocumentFormat` so it can't drift from what `parse` actually
    /// switches on.
    public static let readableExtensions: Set<String> =
        Set(ReadableDocumentFormat.allCases.map(\.rawValue))

    public static func parse(
        fileURL: URL, type: String, title: String, imagesDirectory: URL? = nil,
        recognizeScannedPDFPages: Bool = false
    ) -> ArticleContent? {
        let format = ReadableDocumentFormat(extension: type)
        // The container formats carry their own title and author, so they build
        // the whole `ArticleContent` rather than just its blocks.
        switch format {
        case .epub:
            return (try? Data(contentsOf: fileURL)).flatMap {
                EpubDocumentParser.parse(data: $0, fallbackTitle: title, imagesDirectory: imagesDirectory)
            }
        case .docx:
            return (try? Data(contentsOf: fileURL)).flatMap {
                DocxDocumentParser.parse(data: $0, fallbackTitle: title)
            }
        case .pdf, .rtf, .html, .htm, .xhtml, .md, .markdown, .txt, .text, .none:
            break
        }

        let blocks: [ArticleContent.Block]?
        var resolvedTitle = title
        switch format {
        case .pdf:
            blocks = parsePDF(fileURL: fileURL, recognizeScannedPages: recognizeScannedPDFPages)
        case .md, .markdown:
            blocks = text(at: fileURL).map(MarkdownParser.blocks(from:))
        case .rtf:
            blocks = parseRTF(fileURL: fileURL)
        case .html, .htm, .xhtml:
            let html = text(at: fileURL)
            blocks = html.map(MarkupBlockExtractor.blocks(fromHTML:))
            // A saved page's file name is whatever the browser called it; the
            // page's own `<title>` is what it calls itself.
            if let html, let pageTitle = MarkupBlockExtractor.title(fromHTML: html) {
                resolvedTitle = pageTitle
            }
        case .txt, .text, .none:
            // `.none` is any extension with no specific reader above — a saved
            // file's extension is never trusted to gate import, only to pick a
            // parser, so an unrecognized one still becomes a readable document
            // (best-effort plain text) rather than failing outright.
            blocks = text(at: fileURL).map(PlainTextParser.blocks(from:))
        case .epub, .docx:
            // Handled, and returned, in the switch above.
            blocks = nil
        }
        guard let blocks, !blocks.isEmpty else { return nil }
        return ArticleContent(title: resolvedTitle, blocks: blocks)
    }

    /// UTF-8, then Latin-1 — which cannot fail. A single bad byte in a plain-text
    /// or HTML file should cost that byte, not the whole import (the same rule
    /// the link importer follows, `claudedocs/import-export.md`).
    private static func text(at fileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func parsePDF(fileURL: URL, recognizeScannedPages: Bool) -> [ArticleContent.Block]? {
        guard let document = PDFDocument(url: fileURL), !document.isLocked else { return nil }
        return (0..<document.pageCount).flatMap { index -> [ArticleContent.Block] in
            autoreleasepool {
                guard let page = document.page(at: index) else { return [] }
                if let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return PlainTextParser.blocks(from: text)
                }
                guard recognizeScannedPages, let pageRef = page.pageRef else { return [] }
                return PlainTextParser.blocks(from: recognizeText(on: pageRef))
            }
        }
    }

    private static func recognizeText(on page: CGPDFPage) -> String {
        let box = page.getBoxRect(.cropBox).intersection(page.getBoxRect(.mediaBox))
        let longestEdge = max(box.width, box.height)
        guard longestEdge.isFinite, box.width > 0, box.height > 0 else { return "" }
        // Bound raster memory even for oversized pages and process a page at a time.
        let longestEdgePixels: CGFloat = 2400
        let rotated = page.rotationAngle % 180 != 0
        let scaledWidth = longestEdgePixels * (box.width / longestEdge)
        let scaledHeight = longestEdgePixels * (box.height / longestEdge)
        let width = max(1, Int((rotated ? scaledHeight : scaledWidth).rounded()))
        let height = max(1, Int((rotated ? scaledWidth : scaledHeight).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return "" }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(canvas)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: canvas, rotate: 0, preserveAspectRatio: true))
        context.clip(to: box)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { return "" }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        } catch {
            return ""
        }
    }

    private static func parseRTF(fileURL: URL) -> [ArticleContent.Block]? {
        guard let data = try? Data(contentsOf: fileURL),
              let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil)
        else { return nil }
        return PlainTextParser.blocks(from: attributed.string)
    }
}

/// Splits plain text into paragraph blocks on blank lines. Pure, tested.
public enum PlainTextParser {
    public static func blocks(from text: String) -> [ArticleContent.Block] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { paragraph in
                // Collapse single newlines within a paragraph into spaces.
                let joined = paragraph
                    .split(whereSeparator: { $0.isNewline })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: " ")
                return ArticleContent.Block(kind: .paragraph, text: joined, links: [])
            }
    }
}

/// Minimal Markdown → blocks: ATX headings (#), block quotes (>), unordered
/// (-, *, +) and ordered (1.) list items, everything else paragraphs. Inline
/// emphasis markers are left as-is. Pure, tested.
public enum MarkdownParser {
    public static func blocks(from markdown: String) -> [ArticleContent.Block] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        var blocks: [ArticleContent.Block] = []
        var paragraphLines: [String] = []

        func flushParagraph() {
            let joined = paragraphLines.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty {
                blocks.append(ArticleContent.Block(kind: .paragraph, text: joined, links: []))
            }
            paragraphLines = []
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
                continue
            }
            if let heading = headingText(line) {
                flushParagraph()
                blocks.append(ArticleContent.Block(kind: .heading, text: heading, links: []))
            } else if line.hasPrefix(">") {
                flushParagraph()
                let quote = line.drop(while: { $0 == ">" || $0 == " " })
                blocks.append(ArticleContent.Block(kind: .quote, text: String(quote), links: []))
            } else if let listItem = listItemText(line) {
                flushParagraph()
                blocks.append(ArticleContent.Block(kind: .listItem, text: listItem, links: []))
            } else {
                paragraphLines.append(line)
            }
        }
        flushParagraph()
        return blocks
    }

    /// "## Heading" → "Heading" (1–6 leading #). nil when not a heading.
    private static func headingText(_ line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix(while: { $0 == "#" })
        guard hashes.count <= 6 else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// "- item" / "* item" / "1. item" → "item". nil when not a list item.
    private static func listItemText(_ line: String) -> String? {
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
            return String(line.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)
        }
        // Ordered: digits followed by ". ".
        let digits = line.prefix(while: { $0.isNumber })
        if !digits.isEmpty {
            let afterDigits = line.dropFirst(digits.count)
            if afterDigits.hasPrefix(". ") {
                return String(afterDigits.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

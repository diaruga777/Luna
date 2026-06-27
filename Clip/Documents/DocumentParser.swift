//
//  DocumentParser.swift
//  Clip
//

import ClipModels
import Foundation
import PDFKit

/// Turns an imported document file into `ArticleContent`. PDF text via PDFKit,
/// RTF via attributed string, plain text and Markdown via the pure parsers
/// below. Returns nil when nothing readable can be extracted.
enum DocumentParser {

    static func parse(fileURL: URL, type: String, title: String) -> ArticleContent? {
        let lowercased = type.lowercased()
        let blocks: [ArticleContent.Block]?
        switch lowercased {
        case "pdf":
            blocks = parsePDF(fileURL: fileURL)
        case "md", "markdown":
            blocks = (try? String(contentsOf: fileURL, encoding: .utf8))
                .map(MarkdownParser.blocks(from:))
        case "rtf":
            blocks = parseRTF(fileURL: fileURL)
        default:
            // txt and any other public.text type.
            blocks = (try? String(contentsOf: fileURL, encoding: .utf8))
                .map(PlainTextParser.blocks(from:))
        }
        guard let blocks, !blocks.isEmpty else { return nil }
        return ArticleContent(title: title, blocks: blocks)
    }

    private static func parsePDF(fileURL: URL) -> [ArticleContent.Block]? {
        guard let document = PDFDocument(url: fileURL) else { return nil }
        var text = ""
        for index in 0..<document.pageCount {
            if let pageText = document.page(at: index)?.string {
                text += pageText + "\n\n"
            }
        }
        return PlainTextParser.blocks(from: text)
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
enum PlainTextParser {
    static func blocks(from text: String) -> [ArticleContent.Block] {
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
enum MarkdownParser {
    static func blocks(from markdown: String) -> [ArticleContent.Block] {
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

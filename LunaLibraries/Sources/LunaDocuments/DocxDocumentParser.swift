//
//  DocxDocumentParser.swift
//  LunaDocuments
//

import Foundation
import LunaModels
import SwiftSoup

/// Reads a Word document into `ArticleContent` — the import side of the `.docx`
/// Luna already exports (`ArticleDOCXBuilder`), so a piece that leaves Luna to
/// be edited elsewhere can come back.
///
/// It reads `word/document.xml` directly rather than going through
/// `NSAttributedString`: UIKit's document-type list has no Office Open XML
/// on iOS (that initializer is AppKit's), and the paragraph style is the
/// only thing that says which lines are headings — which is exactly what a
/// reader needs and what a flattened attributed string throws away.
public enum DocxDocumentParser {

    public static func parse(data: Data, fallbackTitle: String) -> ArticleContent? {
        guard let archive = ZipArchiveReader(data: data),
              let xml = archive.text(at: "word/document.xml"),
              let document = try? SwiftSoup.parse(xml, "", Parser.xmlParser()),
              let paragraphs = try? document.getElementsByTag("w:p")
        else { return nil }

        var blocks: [ArticleContent.Block] = []
        for paragraph in paragraphs.array() {
            let text = self.text(of: paragraph)
            guard !text.isEmpty else { continue }
            blocks.append(ArticleContent.Block(
                kind: kind(of: paragraph), text: text, links: []))
        }
        guard !blocks.isEmpty else { return nil }

        return ArticleContent(
            title: coreTitle(in: archive) ?? impliedTitle(from: blocks) ?? fallbackTitle,
            author: coreProperty(in: archive, tag: "dc:creator"),
            blocks: blocks)
    }

    /// A paragraph's text is its runs' `w:t` contents in order. A tab is a
    /// separator, not nothing — `Column\tValue` collapses to one word otherwise.
    private static func text(of paragraph: Element) -> String {
        var pieces: [String] = []
        for node in paragraph.getChildNodes() { collect(node, into: &pieces) }
        return pieces.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collect(_ node: Node, into pieces: inout [String]) {
        if let element = node as? Element {
            switch element.tagName().lowercased() {
            // The raw text, not `text()`: SwiftSoup normalizes whitespace, and
            // a run's trailing space (`xml:space="preserve"`) is the only
            // thing separating it from the next one — "the" + "end" is not
            // "the end".
            case "w:t": pieces.append(element.textNodes().map { $0.getWholeText() }.joined())
            case "w:tab": pieces.append("\t")
            case "w:br", "w:cr": pieces.append(" ")
            // Deleted text in a tracked-changes document is not in the document.
            case "w:delinstrtext", "w:deltext": return
            default: for child in element.getChildNodes() { collect(child, into: &pieces) }
            }
        }
    }

    /// The paragraph style, which is where Word records "this is a heading".
    /// `w:numPr` (a numbering reference) is what makes a paragraph a list item —
    /// bullets are not characters in the text.
    private static func kind(of paragraph: Element) -> ArticleContent.Block.Kind {
        let style = (try? paragraph.getElementsByTag("w:pStyle").first()?.attr("w:val"))?
            .lowercased() ?? ""
        if style.hasPrefix("heading") || style == "title" || style == "subtitle" {
            return .heading
        }
        if style.contains("quote") { return .quote }
        if style == "caption" { return .caption }
        let isNumbered = (try? paragraph.getElementsByTag("w:numPr").first()) != nil
        if style == "listparagraph" || isNumbered { return .listItem }
        return .paragraph
    }

    // MARK: - Core properties

    private static func coreTitle(in archive: ZipArchiveReader) -> String? {
        coreProperty(in: archive, tag: "dc:title")
    }

    private static func coreProperty(in archive: ZipArchiveReader, tag: String) -> String? {
        guard let xml = archive.text(at: "docProps/core.xml"),
              let core = try? SwiftSoup.parse(xml, "", Parser.xmlParser()),
              let text = try? core.getElementsByTag(tag).first()?.text()
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A document with no `dc:title` still usually opens with one: its first
    /// block, when that block is a heading.
    private static func impliedTitle(from blocks: [ArticleContent.Block]) -> String? {
        guard let first = blocks.first, first.kind == .heading else { return nil }
        return first.text
    }
}

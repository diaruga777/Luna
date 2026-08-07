//
//  ArticlePlainTextBuilder.swift
//  Luna
//

import LunaModels
import Foundation

/// Renders extracted article content as unadorned UTF-8 text.
///
/// The point of `.txt` is prose with nothing in the way, so inline link URLs are
/// NOT spliced into the body (that's what the Markdown export is for) — only the
/// article's own source URL appears, in the header. Images become a short
/// placeholder line so the reader can tell a figure stood there.
public struct ArticlePlainTextBuilder {

    public init() {}

    /// The rule under the header and around headings — plain ASCII, so it
    /// survives any encoding or terminal the file is opened in.
    private static let rule = String(repeating: "=", count: 40)

    public func build(content: ArticleContent, sourceURLString: String) -> String {
        var lines: [String] = [content.title]
        if let author = content.author, !author.isEmpty {
            lines.append(L10n.string("Reader_export_plainText_byAuthorLine", author))
        }
        if !sourceURLString.isEmpty {
            lines.append(sourceURLString)
        }
        lines.append(Self.rule)

        for block in content.blocks {
            switch block.kind {
            case .paragraph:
                lines.append(block.text)
            case .heading:
                // Upper-cased so a heading still reads as a heading with no
                // typography available.
                lines.append(block.text.localizedUppercase)
            case .quote:
                lines.append(block.text
                    .components(separatedBy: "\n")
                    .map { "    \($0)" }
                    .joined(separator: "\n"))
            case .listItem:
                lines.append("  • \(block.text)")
            case .tableOfContents:
                lines.append("  \(block.text)")
            case .caption:
                // Labelled, because with no typography a caption would otherwise be
                // indistinguishable from the paragraph it interrupts.
                lines.append(L10n.string("Reader_export_plainText_captionLine", block.text))
            case .image:
                let alt = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append(alt.isEmpty
                    ? L10n.string("Reader_export_plainText_imagePlaceholder")
                    : L10n.string("Reader_export_plainText_imageWithAltLine", alt))
            }
        }

        return lines.filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
    }
}

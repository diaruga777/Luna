//
//  ArticleMarkdownBuilder.swift
//  Luna
//

import LunaModels
import Foundation

/// Renders extracted article content as CommonMark.
///
/// Unlike the EPUB, a `.md` file is a single flat document with nowhere to put
/// bytes, so images are referenced by their ORIGINAL remote URL
/// (`imageURLString`) rather than the downloaded copy — a downloaded-file
/// reference would dangle the moment the file leaves Luna's container. An image
/// block Luna never resolved a URL for is dropped rather than emitted as a
/// broken reference.
public struct ArticleMarkdownBuilder {

    public init() {}

    /// Builds the Markdown document. Front matter is the title as an H1, the
    /// author as an emphasized line, and the source link — the same header the
    /// EPUB chapter opens with.
    public func build(content: ArticleContent, sourceURLString: String) -> String {
        var lines: [String] = ["# \(Self.escape(content.title))"]
        if let author = content.author, !author.isEmpty {
            lines.append("*\(Self.escape(author))*")
        }
        if !sourceURLString.isEmpty {
            lines.append("[\(Self.escape(sourceURLString))](\(Self.escapeURL(sourceURLString)))")
        }
        lines.append("---")

        for block in content.blocks {
            switch block.kind {
            case .paragraph:
                lines.append(Self.inline(block))
            case .heading:
                lines.append("## \(Self.inline(block))")
            case .quote:
                // Every line of a multi-line quote needs its own marker or the
                // continuation lines fall out of the blockquote.
                lines.append(Self.inline(block)
                    .components(separatedBy: "\n")
                    .map { "> \($0)" }
                    .joined(separator: "\n"))
            case .listItem:
                lines.append("- \(Self.inline(block))")
            case .tableOfContents:
                // The page's own chapter list: a flat bullet. In-page `#anchor`
                // jumps don't survive into a standalone file, so it's plain text.
                lines.append("- \(Self.escape(block.text))")
            case .caption:
                // Italic: the closest CommonMark has to a caption, and how the
                // preceding image's credit line conventionally reads.
                lines.append("*\(Self.inline(block))*")
            case .image:
                guard let urlString = block.imageURLString, !urlString.isEmpty else { break }
                lines.append("![\(Self.escape(block.text))](\(Self.escapeURL(urlString)))")
            }
        }

        // One blank line between blocks: in CommonMark that's what separates
        // paragraphs, and it also terminates a bullet/quote run cleanly.
        return lines.filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
    }

    // MARK: - Inline rendering

    /// A block's text with its outbound links as `[label](url)`. An in-page
    /// `#chapter` jump is emitted as plain text — there is no in-file
    /// destination to point it at.
    private static func inline(_ block: ArticleContent.Block) -> String {
        let text = block.text as NSString
        let links = block.links
            .filter { !$0.isInPageAnchor && $0.length > 0 && $0.start >= 0 }
            .filter { $0.start + $0.length <= text.length }
            .sorted { $0.start < $1.start }

        var result = ""
        var cursor = 0
        for link in links {
            // Extraction can hand back overlapping ranges (nested anchors); the
            // first one wins and later overlaps are folded into plain text.
            guard link.start >= cursor else { continue }
            result += escape(text.substring(
                with: NSRange(location: cursor, length: link.start - cursor)))
            let label = escape(text.substring(
                with: NSRange(location: link.start, length: link.length)))
            result += "[\(label)](\(escapeURL(link.urlString)))"
            cursor = link.start + link.length
        }
        result += escape(text.substring(from: cursor))
        return result
    }

    /// Backslash-escapes the CommonMark inline markers, so article prose
    /// containing `*` or `_` or brackets reads literally.
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            if "\\`*_[]".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// A link destination safe inside `(...)`. Parentheses or whitespace in the
    /// URL would close the destination early, so those go in angle brackets.
    static func escapeURL(_ urlString: String) -> String {
        if urlString.contains(where: { $0 == "(" || $0 == ")" || $0 == " " || $0 == "<" || $0 == ">" }) {
            let cleaned = urlString
                .replacingOccurrences(of: "<", with: "%3C")
                .replacingOccurrences(of: ">", with: "%3E")
                .replacingOccurrences(of: " ", with: "%20")
            return "<\(cleaned)>"
        }
        return urlString
    }
}

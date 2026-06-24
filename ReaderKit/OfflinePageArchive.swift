//
//  OfflinePageArchive.swift
//  Clip
//

import Foundation

/// Produces the local HTML snapshot displayed by the Original reader mode. It is
/// intentionally self-contained: scripts and remote resource tags are omitted, and
/// extracted images point at the image files already downloaded into Articles.
enum OfflinePageArchive {

    static func make(content: ArticleContent) -> String {
        let title = escape(content.title)
        let author = content.author.map { "<p class=\"author\">\(escape($0))</p>" } ?? ""
        let body = content.blocks.compactMap { block -> String? in
            switch block.kind {
            case .image:
                guard let file = block.imageFileName else { return nil }
                return "<figure><img src=\"\(escapeAttribute(file))\" loading=\"lazy\"></figure>"
            case .heading:
                return "<h2>\(escape(block.text))</h2>"
            case .quote:
                return "<blockquote>\(escape(block.text))</blockquote>"
            case .listItem:
                return "<p class=\"list\">• \(escape(block.text))</p>"
            case .paragraph:
                return "<p>\(escape(block.text))</p>"
            }
        }.joined(separator: "\n")

        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
        :root { color-scheme: light dark; }
        body { margin: 0 auto; max-width: 42rem; padding: 28px 20px 56px; font: 20px/1.58 Georgia, serif; color: #151515; background: #fff; }
        h1 { font: 700 32px/1.15 -apple-system, BlinkMacSystemFont, sans-serif; margin: 0 0 8px; }
        h2 { font: 700 25px/1.25 -apple-system, BlinkMacSystemFont, sans-serif; margin: 30px 0 10px; }
        .author { color: #6d6d72; font: 15px/1.3 -apple-system, BlinkMacSystemFont, sans-serif; margin: 0 0 28px; }
        p { margin: 0 0 18px; } .list { padding-left: 12px; } blockquote { color: #666; border-left: 3px solid #bbb; margin: 20px 0; padding-left: 16px; }
        figure { margin: 24px 0; } img { display:block; max-width:100%; height:auto; border-radius: 10px; }
        @media (prefers-color-scheme: dark) { body { color: #f3f3f5; background: #111; } .author, blockquote { color:#aaa; } }
        </style></head><body><article><h1>\(title)</h1>\(author)\(body)</article></body></html>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ text: String) -> String {
        escape(text).replacingOccurrences(of: "\"", with: "&quot;")
    }
}

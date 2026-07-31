//
//  SavedArticleSnapshotRenderer.swift
//  Luna
//

import Foundation
import LunaModels

/// Builds the offline fallback shown when a publisher web archive is unavailable
/// or no longer renders as a readable document.
///
/// The snapshot is deliberately self-contained: downloaded images are embedded as
/// data URLs, the CSP permits no network or script execution, and the palette follows
/// the system appearance. "Original" therefore never turns into a live publisher
/// navigation just because archive capture failed.
enum SavedArticleSnapshotRenderer {
    static func html(
        content: ArticleContent,
        sourceURL: URL?,
        imagesDirectory: URL
    ) -> String {
        var body: [String] = [
            "<header>",
            "<p class=\"saved-label\">Saved article</p>",
            "<h1>\(escape(content.title))</h1>",
        ]
        if let author = content.author, !author.isEmpty {
            body.append("<p class=\"byline\">\(escape(author))</p>")
        }
        if let host = sourceURL?.host {
            body.append("<p class=\"source\">\(escape(host))</p>")
        }
        body.append("</header><main>")

        var listIsOpen = false
        for block in content.blocks {
            if block.kind == .listItem, !listIsOpen {
                body.append("<ul>")
                listIsOpen = true
            } else if block.kind != .listItem, listIsOpen {
                body.append("</ul>")
                listIsOpen = false
            }

            let linkedText = inlineHTML(for: block)
            // Destinations of the page's own chapter marks keep their id.
            let id = block.anchorID.map { " id=\"\(escapeAttribute($0))\"" } ?? ""
            switch block.kind {
            case .paragraph:
                body.append("<p\(id)>\(linkedText)</p>")
            case .heading:
                body.append("<h2\(id)>\(linkedText)</h2>")
            case .quote:
                body.append("<blockquote\(id)>\(linkedText)</blockquote>")
            case .listItem:
                body.append("<li\(id)>\(linkedText)</li>")
            case .tableOfContents:
                body.append("<p class=\"toc-row\">\(linkedText)</p>")
            case .caption:
                // Styled as this document's own figure captions are: the caption
                // arrives as its own block, next to (not inside) its <figure>.
                body.append("<p class=\"caption\">\(linkedText)</p>")
            case .image:
                body.append(imageHTML(for: block, imagesDirectory: imagesDirectory))
            }
        }
        if listIsOpen { body.append("</ul>") }
        body.append("</main>")

        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="color-scheme" content="light dark">
          <meta http-equiv="Content-Security-Policy"
                content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
          <title>\(escape(content.title))</title>
          <style>
            :root {
              color-scheme: light dark;
              --background: #ffffff;
              --text: #171717;
              --secondary: #686868;
              --rule: rgba(0, 0, 0, 0.16);
              --link: #1b5fc6;
              --quote: rgba(0, 0, 0, 0.045);
            }
            @media (prefers-color-scheme: dark) {
              :root {
                --background: #000000;
                --text: #f2f2f2;
                --secondary: #a8a8a8;
                --rule: rgba(255, 255, 255, 0.2);
                --link: #8ab4f8;
                --quote: rgba(255, 255, 255, 0.08);
              }
            }
            * { box-sizing: border-box; }
            html, body {
              margin: 0;
              min-height: 100%;
              background: var(--background);
              color: var(--text);
            }
            body {
              padding: 28px clamp(20px, 6vw, 52px) 64px;
              font-family: ui-serif, "New York", Georgia, serif;
              font-size: 19px;
              line-height: 1.58;
              overflow-wrap: anywhere;
              -webkit-text-size-adjust: 100%;
            }
            header, main { width: min(100%, 720px); margin-inline: auto; }
            header { padding-bottom: 24px; border-bottom: 1px solid var(--rule); }
            h1 {
              margin: 6px 0 10px;
              font-size: clamp(2rem, 9vw, 3.25rem);
              line-height: 1.02;
              letter-spacing: -0.035em;
            }
            h2 { margin: 1.7em 0 0.55em; font-size: 1.42em; line-height: 1.16; }
            p { margin: 1.15em 0; }
            .saved-label, .source {
              margin: 0;
              color: var(--secondary);
              font: 600 0.72rem/1.2 -apple-system, BlinkMacSystemFont, sans-serif;
              letter-spacing: 0.09em;
              text-transform: uppercase;
            }
            .byline { margin: 0; color: var(--secondary); font-style: italic; }
            .source { margin-top: 10px; text-transform: none; letter-spacing: 0; }
            a { color: var(--link); text-decoration-thickness: 0.07em; }
            blockquote {
              margin: 1.5em 0;
              padding: 0.9em 1.1em;
              border-left: 3px solid var(--rule);
              background: var(--quote);
              font-style: italic;
            }
            ul { padding-left: 1.35em; }
            li { margin: 0.55em 0; padding-left: 0.25em; }
            figure { margin: 1.7em 0; }
            img { display: block; width: 100%; height: auto; border-radius: 8px; }
            figcaption, .caption {
              margin-top: 0.55em; color: var(--secondary); font-size: 0.78em;
            }
            .caption { margin-bottom: 1.7em; }
            .toc-row { margin: 0.28em 0 0.28em 1.1em; font-size: 0.88em; }
          </style>
        </head>
        <body>
        \(body.joined(separator: "\n"))
        </body>
        </html>
        """
    }

    private static func inlineHTML(for block: ArticleContent.Block) -> String {
        let source = block.text as NSString
        let validLinks = block.links
            // A jump within this same page stays a jump: the snapshot is one
            // document, so the page's own chapter marks keep working offline.
            .map { (range: NSRange(location: $0.start, length: $0.length),
                    url: $0.anchorID.map { "#\($0)" } ?? $0.urlString) }
            .filter {
                $0.range.location >= 0 && $0.range.length > 0
                    && NSMaxRange($0.range) <= source.length
            }
            .sorted { $0.range.location < $1.range.location }

        var result = ""
        var cursor = 0
        for link in validLinks where link.range.location >= cursor {
            result += escapedText(source.substring(with: NSRange(
                location: cursor, length: link.range.location - cursor)))
            result += "<a href=\"\(escapeAttribute(link.url))\">"
            result += escapedText(source.substring(with: link.range))
            result += "</a>"
            cursor = NSMaxRange(link.range)
        }
        if cursor < source.length {
            result += escapedText(source.substring(from: cursor))
        }
        return result
    }

    private static func imageHTML(
        for block: ArticleContent.Block,
        imagesDirectory: URL
    ) -> String {
        guard let fileName = block.imageFileName,
              fileName == URL(fileURLWithPath: fileName).lastPathComponent,
              let mimeType = imageMIMEType(for: fileName),
              let data = try? Data(contentsOf: imagesDirectory.appendingPathComponent(fileName)),
              !data.isEmpty
        else {
            return block.text.isEmpty ? "" : "<p>\(escape(block.text))</p>"
        }

        let caption = block.text.isEmpty
            ? ""
            : "<figcaption>\(escape(block.text))</figcaption>"
        return """
        <figure>
          <img src="data:\(mimeType);base64,\(data.base64EncodedString())"
               alt="\(escapeAttribute(block.text))">
          \(caption)
        </figure>
        """
    }

    private static func imageMIMEType(for fileName: String) -> String? {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return nil
        }
    }

    private static func escapedText(_ text: String) -> String {
        escape(text).replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func escapeAttribute(_ text: String) -> String {
        escape(text).replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

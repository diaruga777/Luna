//
//  MarkupBlockExtractor.swift
//  LunaDocuments
//

import LunaModels
import SwiftSoup

/// Turns a (X)HTML document into `ArticleContent.Block`s — the shared back end
/// for the three imported formats that are markup underneath: a `.html`/`.xhtml`
/// file, and every chapter of an EPUB.
///
/// Deliberately NOT the web article extractor. That one's job is to find the
/// article inside a page full of navigation, promos and comment threads, and it
/// scores candidates to do it — which is the wrong instinct here, where the file
/// IS the content and a short chapter would lose to nothing at all. This takes
/// the document's own block elements, in the document's own order.
public enum MarkupBlockExtractor {

    /// Block-level elements worth a block of their own, as one selector so
    /// SwiftSoup returns them in document order.
    private static let blockSelector =
        "h1, h2, h3, h4, h5, h6, p, blockquote, li, dt, dd, pre, figcaption"

    /// Elements that carry no prose. `script`/`style` would otherwise arrive as
    /// paragraphs of source code.
    private static let strippedSelector = "script, style, noscript, template"

    public static func blocks(fromHTML html: String) -> [ArticleContent.Block] {
        guard let document = try? SwiftSoup.parse(html),
              let body = document.body()
        else { return PlainTextParser.blocks(from: html) }
        _ = try? body.select(strippedSelector).remove()

        guard let matches = try? body.select(blockSelector) else { return [] }
        // A `p` inside a `blockquote` matches the selector too, and emitting both
        // would print the quote twice — once as itself and once as its contents.
        // The OUTER element wins: it knows what kind of block this is.
        let matched = Set(matches.array().map(ObjectIdentifier.init))

        var blocks: [ArticleContent.Block] = []
        for element in matches.array() {
            guard !hasMatchedAncestor(element, in: matched) else { continue }
            let text = (try? element.text())?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { continue }
            blocks.append(ArticleContent.Block(kind: kind(of: element), text: text, links: []))
        }
        // A document that lays its prose out in bare `div`s — which badly made
        // ebooks do — matches nothing above. Its text is still text.
        if blocks.isEmpty, let text = try? body.text() {
            return PlainTextParser.blocks(from: text)
        }
        return blocks
    }

    /// The document's own `<title>`, else its first heading. Trimmed, and nil
    /// when neither says anything.
    public static func title(fromHTML html: String) -> String? {
        guard let document = try? SwiftSoup.parse(html) else { return nil }
        let candidates = [
            try? document.title(),
            try? document.select("h1, h2").first()?.text(),
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func hasMatchedAncestor(
        _ element: Element, in matched: Set<ObjectIdentifier>
    ) -> Bool {
        var parent = element.parent()
        while let current = parent {
            if matched.contains(ObjectIdentifier(current)) { return true }
            parent = current.parent()
        }
        return false
    }

    private static func kind(of element: Element) -> ArticleContent.Block.Kind {
        switch element.tagName().lowercased() {
        case "h1", "h2", "h3", "h4", "h5", "h6", "dt": return .heading
        case "blockquote": return .quote
        case "li": return .listItem
        case "figcaption": return .caption
        default: return .paragraph
        }
    }
}

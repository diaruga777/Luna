//
//  PluginHTMLMetadata.swift
//  LunaPluginKit
//

import Foundation
import SwiftSoup

/// `luna.html.meta` and `luna.html.jsonLD` over SwiftSoup.
///
/// Every page states the same six or seven facts — title, description,
/// canonical URL, lead image, author, publication date, language — in four
/// competing vocabularies, and a generated plugin reads one of them and misses
/// the page that uses another. This reads all four in one fixed order.
///
/// `plugin_host.js` (DOMParser) and `tools/plugin-sim/bridge.mjs` (linkedom)
/// implement the same rules; `LunaTests/Fixtures/Plugins/html-subset.spec.js`
/// is the specification the three run.
public enum PluginHTMLMetadata {

    /// The keys `meta` may answer, in the order `docs/plugins/api.md` lists
    /// them. A key whose sources are all absent is omitted, never empty.
    public static let keys = [
        "title", "description", "canonical", "image", "author", "published",
        "siteName", "language", "type",
    ]

    /// The JSON-LD `@type`s that fill a gap. Anything else on the page is
    /// still returned by `jsonLD`, but does not answer for the document.
    static let documentTypes: Set<String> = [
        "Article", "NewsArticle", "BlogPosting", "Product",
    ]

    /// The page's own account of itself. Absent keys are omitted.
    public static func read(from document: Document) -> [String: String] {
        let reader = Reader(document: document)
        var result: [String: String] = [:]
        for key in keys {
            if let value = reader.value(for: key) { result[key] = value }
        }
        return result
    }

    /// Every `<script type="application/ld+json">` body, parse errors skipped
    /// and a `@graph` array flattened one level, so a caller looks for its
    /// `@type` in one flat list rather than in two shapes.
    public static func jsonLD(in element: Element) -> [Any] {
        guard let scripts = try? element.select("script[type=application/ld+json]") else {
            return []
        }
        var out: [Any] = []
        for script in scripts.array() {
            let source = script.data().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty,
                  let parsed = try? JSONSerialization.jsonObject(
                    with: Data(source.utf8), options: [.fragmentsAllowed])
            else { continue }
            append(parsed, to: &out)
        }
        return out
    }

    /// A top-level array is spread, and so is one `@graph` inside an object.
    /// Deeper nesting is left as the page wrote it.
    private static func append(_ value: Any, to out: inout [Any]) {
        if let list = value as? [Any] {
            for entry in list { appendFlattenedGraph(entry, to: &out) }
            return
        }
        appendFlattenedGraph(value, to: &out)
    }

    private static func appendFlattenedGraph(_ value: Any, to out: inout [Any]) {
        if let object = value as? [String: Any], let graph = object["@graph"] as? [Any] {
            out.append(contentsOf: graph)
            return
        }
        out.append(value)
    }

    /// One document's answers, each source consulted only when an earlier one
    /// said nothing.
    private struct Reader {
        let document: Document
        /// The JSON-LD objects whose `@type` names a document, parsed once.
        let linkedData: [[String: Any]]

        init(document: Document) {
            self.document = document
            linkedData = PluginHTMLMetadata.jsonLD(in: document)
                .compactMap { $0 as? [String: Any] }
                .filter { object in
                    let raw = object["@type"]
                    let names = (raw as? String).map { [$0] } ?? (raw as? [String]) ?? []
                    return names.contains { PluginHTMLMetadata.documentTypes.contains($0) }
                }
        }

        func value(for key: String) -> String? {
            switch key {
            case "title":
                return property("og:title") ?? property("twitter:title")
                    ?? clean(try? document.title()) ?? linked("headline") ?? linked("name")
            case "description":
                return property("og:description") ?? property("twitter:description")
                    ?? named("description")
            case "canonical":
                return absolute(property("og:url") ?? link(rel: "canonical"))
            case "image":
                return absolute(
                    property("og:image") ?? property("og:image:url")
                        ?? property("twitter:image") ?? property("twitter:image:src")
                        ?? linkedImage())
            case "author":
                return named("author") ?? property("article:author") ?? linkedAuthor()
            case "published":
                return property("article:published_time") ?? named("date")
                    ?? named("pubdate") ?? itemprop("datePublished") ?? linked("datePublished")
            case "siteName":
                return property("og:site_name") ?? named("application-name")
            case "language":
                return clean(try? document.select("html").first()?.attr("lang"))
                    ?? httpEquiv("content-language") ?? linked("inLanguage")
            case "type":
                return property("og:type")
            default:
                return nil
            }
        }

        /// `<meta property=…>`, and `<meta name=…>` for the same key: Twitter
        /// cards are written both ways in the wild and a page that picked the
        /// other spelling is not a page without metadata.
        private func property(_ name: String) -> String? {
            attribute("meta[property=\"\(name)\"]", "content")
                ?? attribute("meta[name=\"\(name)\"]", "content")
        }

        private func named(_ name: String) -> String? {
            attribute("meta[name=\"\(name)\"]", "content")
        }

        private func httpEquiv(_ name: String) -> String? {
            attribute("meta[http-equiv=\"\(name)\"]", "content")
        }

        private func itemprop(_ name: String) -> String? {
            attribute("meta[itemprop=\"\(name)\"]", "content")
                ?? attribute("[itemprop=\"\(name)\"]", "datetime")
        }

        private func link(rel: String) -> String? {
            attribute("link[rel=\"\(rel)\"]", "href")
        }

        private func attribute(_ selector: String, _ name: String) -> String? {
            guard let element = try? document.select(selector).first() else { return nil }
            return clean(try? element.attr(name))
        }

        /// `author` is a string, an object with a `name`, or a list of either.
        private func linkedAuthor() -> String? {
            for object in linkedData {
                guard let author = object["author"] else { continue }
                if let text = clean(author as? String) { return text }
                if let single = author as? [String: Any],
                   let text = clean(single["name"] as? String) { return text }
                if let list = author as? [Any] {
                    for entry in list {
                        if let text = clean(entry as? String) { return text }
                        if let object = entry as? [String: Any],
                           let text = clean(object["name"] as? String) { return text }
                    }
                }
            }
            return nil
        }

        /// `image` is a URL, an `ImageObject` with a `url`, or a list; the
        /// first entry wins.
        private func linkedImage() -> String? {
            for object in linkedData {
                guard let image = object["image"] else { continue }
                if let text = clean(image as? String) { return text }
                if let single = image as? [String: Any],
                   let text = clean(single["url"] as? String) { return text }
                if let list = image as? [Any], let first = list.first {
                    if let text = clean(first as? String) { return text }
                    if let object = first as? [String: Any],
                       let text = clean(object["url"] as? String) { return text }
                }
            }
            return nil
        }

        private func linked(_ field: String) -> String? {
            for object in linkedData {
                if let text = clean(object[field] as? String) { return text }
            }
            return nil
        }

        /// Resolves against the document's own base, so a plugin never has to
        /// join a root-relative `og:image` itself.
        private func absolute(_ value: String?) -> String? {
            guard let value else { return nil }
            let base = document.getBaseUri()
            guard !base.isEmpty, let resolved = URL(string: value, relativeTo: URL(string: base))
            else { return value }
            return resolved.absoluteString
        }

        private func clean(_ value: String?) -> String? {
            guard let value else { return nil }
            let text = PluginTextParsing.collapseWhitespace(value)
            return text.isEmpty ? nil : text
        }
    }
}

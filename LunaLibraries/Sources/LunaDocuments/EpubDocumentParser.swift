//
//  EpubDocumentParser.swift
//  LunaDocuments
//

import Foundation
import LunaModels
import SwiftSoup

/// Reads an EPUB into one `ArticleContent` — the import side of the format Luna
/// already exports (`EpubBuilder`) and emails to Kindle.
///
/// The whole book becomes ONE reading-list item rather than one per chapter.
/// That is what the reader is: a saved thing you read top to bottom, with the
/// chapters as headings inside it, and it is what makes an imported book work
/// with everything an article already gets — RSVP, read-aloud, export, Kindle.
public enum EpubDocumentParser {

    /// A book longer than this stops being read. 40k blocks is a very long novel
    /// several times over; past it, a malformed archive is the likelier
    /// explanation than a real book, and the JSON has to be held in memory.
    private static let blockLimit = 40_000

    public static func parse(data: Data, fallbackTitle: String) -> ArticleContent? {
        guard let archive = ZipArchiveReader(data: data),
              let packagePath = packagePath(in: archive),
              let package = archive.text(at: packagePath).flatMap(parseXML)
        else { return nil }

        let directory = (packagePath as NSString).deletingLastPathComponent
        let manifest = manifestHrefs(in: package, relativeTo: directory)

        var blocks: [ArticleContent.Block] = []
        for path in spinePaths(in: package, manifest: manifest) {
            guard blocks.count < blockLimit, let chapter = archive.text(at: path) else { continue }
            var chapterBlocks = MarkupBlockExtractor.blocks(fromHTML: chapter)
            guard !chapterBlocks.isEmpty else { continue }
            // A chapter that names itself only in its `<title>` — no `h1` in the
            // body — would otherwise run straight on from the previous one with
            // nothing marking the break.
            if !chapterBlocks.contains(where: { $0.kind == .heading }),
               let heading = MarkupBlockExtractor.title(fromHTML: chapter) {
                chapterBlocks.insert(
                    ArticleContent.Block(kind: .heading, text: heading, links: []), at: 0)
            }
            blocks.append(contentsOf: chapterBlocks)
        }
        guard !blocks.isEmpty else { return nil }

        return ArticleContent(
            title: metadata(in: package, tag: "dc:title") ?? fallbackTitle,
            author: metadata(in: package, tag: "dc:creator"),
            blocks: Array(blocks.prefix(blockLimit)))
    }

    // MARK: - Package document

    /// Where the OPF lives, per `META-INF/container.xml` — an EPUB is allowed to
    /// put it anywhere, so this is never guessed. A book with no container (or a
    /// container naming no rootfile) falls back to the first `.opf` in the
    /// archive, which is what every real-world repair tool does.
    private static func packagePath(in archive: ZipArchiveReader) -> String? {
        if let container = archive.text(at: "META-INF/container.xml").flatMap(parseXML),
           let path = try? container.getElementsByTag("rootfile").first()?.attr("full-path"),
           !path.isEmpty {
            return normalize(path)
        }
        return archive.paths.first { $0.lowercased().hasSuffix(".opf") }
    }

    private static func parseXML(_ text: String) -> Document? {
        try? SwiftSoup.parse(text, "", Parser.xmlParser())
    }

    private static func metadata(in package: Document, tag: String) -> String? {
        // Namespace prefixes are the publisher's choice: `dc:title` is
        // overwhelmingly common but the bare `title` is legal when the Dublin
        // Core namespace is the default one.
        let bare = String(tag.split(separator: ":").last ?? "")
        for candidate in [tag, bare] {
            guard let text = try? package.getElementsByTag(candidate).first()?.text()
            else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Manifest id → archive path, for the ids the spine will name.
    private static func manifestHrefs(
        in package: Document, relativeTo directory: String
    ) -> [String: String] {
        guard let items = try? package.getElementsByTag("item") else { return [:] }
        var hrefs: [String: String] = [:]
        for item in items.array() {
            guard let id = try? item.attr("id"), !id.isEmpty,
                  let href = try? item.attr("href"), !href.isEmpty
            else { continue }
            hrefs[id] = resolve(href, in: directory)
        }
        return hrefs
    }

    /// The reading order. Non-linear items (`linear="no"` — the copyright page a
    /// reading system reaches only from a link) are left out, which is exactly
    /// the spec's intent for a straight-through read.
    private static func spinePaths(in package: Document, manifest: [String: String]) -> [String] {
        guard let refs = try? package.getElementsByTag("itemref") else { return [] }
        return refs.array().compactMap { ref in
            guard (try? ref.attr("linear"))?.lowercased() != "no",
                  let idref = try? ref.attr("idref")
            else { return nil }
            return manifest[idref]
        }
    }

    // MARK: - Paths

    /// An `href` resolved against the package document's own directory, with the
    /// fragment dropped and percent-escapes undone — a zip stores the literal
    /// name, and a chapter called `Ch 1.xhtml` is referenced as `Ch%201.xhtml`.
    private static func resolve(_ href: String, in directory: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        let withoutFragment = decoded.split(separator: "#", maxSplits: 1).first.map(String.init)
            ?? decoded
        guard !directory.isEmpty else { return normalize(withoutFragment) }
        return normalize(directory + "/" + withoutFragment)
    }

    /// Collapses `.`/`..` and any leading slash, so the result matches the zip's
    /// own entry names.
    private static func normalize(_ path: String) -> String {
        var components: [String] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(String(component))
            }
        }
        return components.joined(separator: "/")
    }
}

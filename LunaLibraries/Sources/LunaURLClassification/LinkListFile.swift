//
//  LinkListFile.swift
//  LunaURLClassification
//

import Foundation

/// The two ordered lists a Luna link export carries — the live saves and the
/// archive — and whether they really came from a Luna-shaped file.
public struct LinkListDocument: Equatable, Sendable {
    /// Ordinary saves, in file order (which the export writes newest-first).
    public var links: [String]
    /// Archived saves, in file order.
    public var archived: [String]
    /// Titles by URL, for the links that came with one. A Luna markdown export
    /// writes `[Title](url)`, so a re-import can show the real headline in the
    /// review list without fetching anything; a bare-URL file leaves this empty
    /// and the sheet fetches its own previews.
    public var titles: [String: String]
    /// True only when the source really carried a section structure — a CSV with a
    /// section column, or a markdown export with its `## Links` / `## Archive`
    /// headings. False means the links were SCRAPED out of arbitrary text, where
    /// nothing says which list a link belonged to — so every one of them arrives
    /// as an ordinary save and `archived` is empty.
    public var isStructured: Bool

    public init(
        links: [String] = [], archived: [String] = [],
        titles: [String: String] = [:], isStructured: Bool = false
    ) {
        self.links = links
        self.archived = archived
        self.titles = titles
        self.isStructured = isStructured
    }

    public var isEmpty: Bool { links.isEmpty && archived.isEmpty }
    public var count: Int { links.count + archived.count }
}

/// The one entry point for reading a picked file, whatever shape it is.
///
/// Three tiers, most structured first, each falling through to the next so a file
/// never costs the user the links sitting in it:
///
/// 1. **Luna's own markdown** (`LinkListMarkdown`) — and anything else whose text
///    carries a recognizable `Links` / `Archive` heading, however mangled. This is
///    the format Luna writes.
/// 2. **A section CSV** (`LinkListCSV`) — a header naming a section column and a
///    url column, which is what Pocket's `status` and Instapaper's `Folder`
///    exports are. Honors their archive split.
/// 3. **A scrape** — every http(s) link in the text, in reading order, all as
///    ordinary saves. Covers a one-URL-per-line list, a foreign CSV with no
///    section column, a pasted email.
///
/// Pure and unit-tested (`LinkListFileTests`): no file access, no networking.
public enum LinkListFile {

    public static func parse(_ text: String) -> LinkListDocument {
        let cleaned = strippingByteOrderMarks(text)
        if let markdown = LinkListMarkdown.parse(cleaned), !markdown.isEmpty { return markdown }
        if let csv = LinkListCSV.parseStructured(cleaned), !csv.isEmpty { return csv }
        return LinkListDocument(
            links: LinkListCSV.scrapeLinks(from: cleaned), isStructured: false)
    }

    /// Drops every U+FEFF, at the front or anywhere else.
    ///
    /// Done over `unicodeScalars` rather than with `hasPrefix`/
    /// `replacingOccurrences`: U+FEFF is a default-ignorable code point, so
    /// Swift's canonically-equivalent String comparison does NOT see a leading
    /// BOM as a prefix — a UTF-8-with-BOM CSV (what a Windows spreadsheet
    /// writes) kept its marker glued to the first header name and the file
    /// silently lost its structure.
    static func strippingByteOrderMarks(_ text: String) -> String {
        guard text.unicodeScalars.contains("\u{FEFF}") else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != "\u{FEFF}" }))
    }
}

//
//  LinkListCSV.swift
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
    /// True only when the source carried a recognized header with a section
    /// column. False means the links were SCRAPED out of arbitrary text, where
    /// nothing says which list a link belonged to — so every one of them arrives
    /// as an ordinary save and `archived` is empty.
    public var isStructured: Bool

    public init(links: [String] = [], archived: [String] = [], isStructured: Bool = false) {
        self.links = links
        self.archived = archived
        self.isStructured = isStructured
    }

    public var isEmpty: Bool { links.isEmpty && archived.isEmpty }
    public var count: Int { links.count + archived.count }
}

/// Luna's link-list interchange format, and the best-effort reader for
/// everything that isn't it.
///
/// The written shape is a two-column CSV — `section,url` — one row per link,
/// with `list` and `archive` as the only section values. That was chosen over
/// literal blocks separated by blank lines for two reasons: it stays a *valid*
/// CSV that a spreadsheet opens correctly, and a reader that knows nothing about
/// the format still sees one link per line, so the fallback scrape below
/// recovers everything (minus the archive split) from the same bytes.
///
/// Pure and unit-tested (`LinkListCSVTests`): no file access, no networking.
public enum LinkListCSV {

    /// The exported header row. Recognizing it on the way back in is what
    /// separates a structured import from a scrape.
    public static let header = "section,url"

    /// Section values. Only these two are written; on read, anything beginning
    /// `arch` is the archive and everything else is an ordinary save.
    public static let listSectionValue = "list"
    public static let archiveSectionValue = "archive"

    /// Header names accepted for the section column, lowercased. `status` and
    /// `folder` are here on purpose: the two most common read-later exports
    /// (Pocket's `status`, Instapaper's `Folder`) already spell their archive
    /// `archive`, so the `arch`-prefix rule below imports those files WITH their
    /// archive split instead of flattening them.
    private static let sectionColumnNames: Set<String> = [
        "section", "list", "kind", "group", "status", "state", "folder",
    ]
    /// Header names accepted for the URL column, lowercased.
    private static let urlColumnNames: Set<String> = ["url", "link", "address", "urls"]

    // MARK: - Encoding

    /// Renders the two lists as the CSV above, in the order given.
    public static func encode(links: [String], archived: [String]) -> String {
        var lines = [header]
        lines.reserveCapacity(links.count + archived.count + 1)
        for url in links { lines.append("\(listSectionValue),\(escape(url))") }
        for url in archived { lines.append("\(archiveSectionValue),\(escape(url))") }
        // A trailing newline: POSIX text, and it keeps the last row from being
        // treated as truncated by strict readers.
        return lines.joined(separator: "\n") + "\n"
    }

    /// RFC 4180 quoting. URLs legitimately contain commas (and, rarely, quotes),
    /// so this is not decoration — an unquoted `?a=1,2` would split into two
    /// fields and the link would be lost.
    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
        else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Decoding

    /// Reads whatever the user picked.
    ///
    /// A recognized header (a section column AND a url column) takes the
    /// structured path and honors the archive. Anything else — a one-URL-per-line
    /// text file, a CSV from another app, a pasted email, even a Luna export whose
    /// header got mangled — falls back to scraping every link out of the raw text
    /// in reading order. A structured file that yields no usable rows also falls
    /// back, so a valid header above unparseable rows still imports something.
    public static func parse(_ text: String) -> LinkListDocument {
        let cleaned = strippingByteOrderMarks(text)
        if let structured = parseStructured(cleaned), !structured.isEmpty { return structured }
        return LinkListDocument(links: scrapeLinks(from: cleaned), isStructured: false)
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

    /// The structured path: nil when the first non-empty record isn't a header
    /// naming both columns.
    private static func parseStructured(_ text: String) -> LinkListDocument? {
        let records = parseRecords(text)
        // `parseRecords` already drops all-empty records, so the header is the
        // first record there is.
        guard let header = records.first else { return nil }

        let names = header.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard let sectionColumn = names.firstIndex(where: sectionColumnNames.contains),
              let urlColumn = names.firstIndex(where: urlColumnNames.contains),
              sectionColumn != urlColumn
        else { return nil }

        var document = LinkListDocument(isStructured: true)
        var seen = Set<String>()
        for record in records.dropFirst() {
            guard record.count > urlColumn,
                  isSingleURLCandidate(record[urlColumn]),
                  let url = URLUnwrapper.ingestURL(from: record[urlColumn], allowBareHost: true)
            else { continue }
            let normalized = url.absoluteString
            guard seen.insert(normalized).inserted else { continue }
            let section = record.count > sectionColumn
                ? record[sectionColumn].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                : ""
            if section.hasPrefix("arch") {
                document.archived.append(normalized)
            } else {
                document.links.append(normalized)
            }
        }
        return document
    }

    /// Every http(s) link in the text, in reading order, first occurrence only.
    ///
    /// The text is split into CSV fields FIRST, and each field is then read on
    /// its own. That field boundary is load-bearing, not tidiness: a comma is
    /// legal in a URL path, so `NSDataDetector` run over a whole
    /// `title,url,time_added` row happily swallows the following columns and
    /// returns `https://example.com/1,1699999999` — a link that resolves to
    /// nothing. Bounding each match to one field makes a foreign read-later CSV
    /// import correctly.
    ///
    /// Within a field, an exact URL wins outright; anything else is handed to
    /// `NSDataDetector`, which is what every other link-out-of-text path in Luna
    /// uses (`ShareTextURL`, the mail importer) — so a file and a shared note
    /// recover the same links from the same prose. Bare hosts (`example.com`),
    /// which hand-written lists are full of, are picked up either way.
    static func scrapeLinks(from text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue)
        var found: [String] = []
        var seen = Set<String>()

        func admit(_ candidate: String) {
            // The candidate goes through the same offline unwrap + http(s) gate
            // as a typed URL, so a Facebook shim or a classic Google News id
            // resolves and a `mailto:`/`tel:` match is refused.
            //
            // Bare hosts are deliberately NOT accepted here and are left to the
            // detector, which knows real TLDs: `allowBareHost` would turn an
            // ordinary decimal in some unrelated CSV column into `https://3.14`.
            guard isSingleURLCandidate(candidate),
                  let url = URLUnwrapper.ingestURL(from: candidate) else { return }
            let normalized = url.absoluteString
            if seen.insert(normalized).inserted { found.append(normalized) }
        }

        for record in parseRecords(text) {
            for field in record {
                let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let before = found.count
                admit(trimmed)
                guard found.count == before, let detector else { continue }
                detector.enumerateMatches(
                    in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)
                ) { match, _, _ in
                    if let matched = match?.url { admit(matched.absoluteString) }
                }
            }
        }
        return found
    }

    /// Whether a field could be one whole URL and nothing else.
    ///
    /// `URL(string:)` percent-encodes interior whitespace rather than refusing
    /// it, so `https://a.example/1\thttps://b.example/2` parses as ONE valid URL
    /// ending in `%09https://…` — a tab-separated pair of links imported as a
    /// single dead one. Anything with interior whitespace is text that happens to
    /// contain links, and belongs to the detector.
    static func isSingleURLCandidate(_ field: String) -> Bool {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }

    // MARK: - CSV reader

    /// Splits CSV text into records of fields, honoring RFC 4180 quoting
    /// (embedded commas, doubled quotes, newlines inside quotes) and all three
    /// line endings. Empty records are dropped.
    ///
    /// Walked over UNICODE SCALARS, not `Character`s. Swift treats `\r\n` as a
    /// single grapheme cluster, so a `Character`-based reader matches neither
    /// `"\r"` nor `"\n"` on a Windows-authored CSV and silently swallows every
    /// line break into one enormous field — the whole file becomes one record.
    static func parseRecords(_ text: String) -> [[String]] {
        let scalars = Array(text.unicodeScalars)
        var records: [[String]] = []
        var fields: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var index = 0

        func endField() {
            fields.append(String(field))
            field = String.UnicodeScalarView()
        }
        func endRecord() {
            endField()
            if fields.contains(where: { !$0.isEmpty }) { records.append(fields) }
            fields = []
        }

        while index < scalars.count {
            let scalar = scalars[index]
            if inQuotes {
                if scalar == "\"" {
                    // A doubled quote is a literal one; a lone quote closes the field.
                    if index + 1 < scalars.count, scalars[index + 1] == "\"" {
                        field.append("\"")
                        index += 2
                        continue
                    }
                    inQuotes = false
                } else {
                    field.append(scalar)
                }
                index += 1
                continue
            }
            switch scalar {
            case "\"" where field.isEmpty:
                inQuotes = true
            case ",":
                endField()
            case "\n":
                endRecord()
            case "\r":
                endRecord()
                // Swallow the LF of a CRLF pair rather than ending a second,
                // empty record.
                if index + 1 < scalars.count, scalars[index + 1] == "\n" { index += 1 }
            default:
                field.append(scalar)
            }
            index += 1
        }
        if !field.isEmpty || !fields.isEmpty { endRecord() }
        return records
    }
}

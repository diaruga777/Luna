//
//  LinkListMarkdown.swift
//  LunaURLClassification
//

import Foundation

/// Luna's link-list interchange format: **markdown**, one bullet per link, under
/// a `## Links` and a `## Archive` heading.
///
///     # Luna Links
///
///     Exported 2026-08-06 by Luna. The two headings below are what tells Luna
///     which links are archived when this file is imported again.
///
///     ## Links (2)
///
///     - [Some Piece](https://example.com/a)
///     - https://example.com/b
///
///     ## Archive (1)
///
///     - [An Old One](https://example.com/old)
///
/// It replaced a `section,url` CSV, which was correct and unreadable: AirDropping
/// it opened the file in Notes, and what came back out of Notes was text with no
/// CSV left in it — so the whole file re-imported as one flat list and the archive
/// split was lost. Markdown survives that trip because its structure is *prose*: a
/// heading is still a heading after a round trip through a rich-text editor that
/// dropped the `##`, and a bullet is still a line with a link on it.
///
/// Which is exactly what the reader below leans on. It does NOT require the `##`,
/// the `-`, or even the exact word: a **short line with no URL in it** whose
/// letters start with `arch` opens the archive, and one that reads `links` /
/// `unread` / `saved` / `inbox` opens the live list. `**Archive**`, `ARCHIVE:`,
/// `## Archive (12)` and a bare `Archive` all work.
///
/// The structural words (`Links`, `Archive`) and the preamble are deliberately NOT
/// localized, for the same reason the export FILENAME isn't: this file travels
/// between devices, apps and people, and its headings are the machine-readable
/// half of the format. Pure and unit-tested (`LinkListMarkdownTests`).
public enum LinkListMarkdown {

    /// The heading words written out, and the ones recognized on the way back in.
    static let linksHeading = "Links"
    static let archiveHeading = "Archive"
    private static let listHeadingWords = ["link", "unread", "saved", "inbox", "readinglist"]
    private static let archiveHeadingPrefix = "arch"
    /// A heading is a SHORT line. Long prose that happens to mention an archive is
    /// prose; `## Archive (128)` is a heading. 60 characters clears every heading
    /// Luna writes and every decorated form of one a rich-text editor produces.
    private static let maximumHeadingLength = 60

    // MARK: - Encoding

    /// Renders the two lists, in the order given, with each link's title when
    /// there is one.
    ///
    /// - Parameters:
    ///   - appName: the exporting app, named in the preamble so a file found later
    ///     says where it came from.
    ///   - exportedOn: stamped as `yyyy-MM-dd`, POSIX, so it reads the same
    ///     everywhere.
    public static func encode(
        _ document: LinkListDocument, appName: String, exportedOn: Date = Date()
    ) -> String {
        var lines: [String] = [
            "# \(appName) Links",
            "",
            "Exported \(dateStamp(exportedOn)). Keep the two headings below and Luna "
                + "reads the archive back as an archive when this file is imported again.",
        ]
        for (heading, urls) in [
            (linksHeading, document.links), (archiveHeading, document.archived),
        ] where !urls.isEmpty {
            lines.append("")
            lines.append("## \(heading) (\(urls.count))")
            lines.append("")
            lines.append(contentsOf: urls.map { bullet(for: $0, title: document.titles[$0]) })
        }
        // A trailing newline: POSIX text, and a reader that splits on newlines
        // doesn't have to treat the last line as a special case.
        return lines.joined(separator: "\n") + "\n"
    }

    /// One link's line: `- [Title](url)`, or a bare `- url` when there's no title.
    ///
    /// The title is flattened to one line and stripped of the brackets that would
    /// close the link text early; a URL holding a space or a parenthesis is wrapped
    /// in `<…>` (CommonMark's own escape) so the destination survives.
    static func bullet(for urlString: String, title: String?) -> String {
        let destination = urlString.contains(where: { $0 == " " || $0 == "(" || $0 == ")" })
            ? "<\(urlString)>" : urlString
        guard let cleaned = title.map(flattened), !cleaned.isEmpty else {
            return "- \(destination)"
        }
        return "- [\(cleaned)](\(destination))"
    }

    private static func flattened(_ title: String) -> String {
        title
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    private static func dateStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - Decoding

    /// Reads sectioned text, or returns nil when the text carries no section
    /// heading at all — which is the signal for `LinkListFile` to try the CSV
    /// reader and then the flat scrape.
    ///
    /// Links found BEFORE the first heading are ordinary saves: a file that opens
    /// with a couple of loose links above its `## Archive` keeps them rather than
    /// dropping them for being outside a section.
    public static func parse(_ text: String) -> LinkListDocument? {
        var document = LinkListDocument(isStructured: true)
        var sawHeading = false
        var inArchive = false
        var seen = Set<String>()

        for line in text.components(separatedBy: .newlines) {
            if let heading = headingKind(of: line) {
                sawHeading = true
                inArchive = (heading == .archive)
                continue
            }
            for found in links(in: line) {
                guard seen.insert(found.urlString).inserted else { continue }
                if inArchive {
                    document.archived.append(found.urlString)
                } else {
                    document.links.append(found.urlString)
                }
                if let title = found.title { document.titles[found.urlString] = title }
            }
        }
        return sawHeading ? document : nil
    }

    enum HeadingKind: Equatable { case links, archive }

    /// The punctuation a heading may carry on top of letters, digits and spaces:
    /// markdown and rich-text decoration, a trailing colon, a bracketed count.
    /// Everything else — a dot, a slash, an `@` — means the line is not a heading
    /// but something with an address in it, which is the whole point: a bookmark
    /// whose title is "Archive" (`archive.example.com`, `[Archive](https://…)`)
    /// must not re-section the file.
    private static let headingDecoration = Set("#*_~>-–—:()[]")

    /// Whether a line is a section heading, ignoring the decoration around the
    /// word: `##`, `**`, `>`, a leading bullet, a trailing count or colon.
    static func headingKind(of line: String) -> HeadingKind? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumHeadingLength,
              trimmed.allSatisfy({
                  $0.isLetter || $0.isNumber || $0.isWhitespace
                      || headingDecoration.contains($0)
              })
        else { return nil }
        // Everything that isn't a letter goes, so `## **Archive** (12):` and
        // `Reading List` both reduce to their word.
        let word = trimmed.lowercased().filter { $0.isLetter }
        guard !word.isEmpty else { return nil }
        if word.hasPrefix(archiveHeadingPrefix) { return .archive }
        return listHeadingWords.contains(where: word.hasPrefix) ? .links : nil
    }

    struct FoundLink: Equatable {
        let urlString: String
        let title: String?
    }

    /// Every link on one line, markdown-style first and then bare.
    ///
    /// The markdown matches are cut OUT of the line before the bare scrape runs, so
    /// a `[Title](url)` link isn't also reported as an untitled one — and any bare
    /// URL sitting next to it on the same line still is.
    static func links(in line: String) -> [FoundLink] {
        var found: [FoundLink] = []
        var residual = line
        for match in markdownMatches(in: line) {
            guard let url = normalized(match.destination) else { continue }
            let title = match.text.trimmingCharacters(in: .whitespacesAndNewlines)
            found.append(FoundLink(urlString: url, title: title.isEmpty ? nil : title))
            residual = residual.replacingOccurrences(of: match.whole, with: " ")
        }
        // The same scrape every other link-out-of-text path in Luna uses, so a
        // hand-written list and a shared note recover the same links.
        found.append(contentsOf: LinkListCSV.scrapeLinks(from: residual)
            .map { FoundLink(urlString: $0, title: nil) })
        return found
    }

    private struct MarkdownMatch {
        let whole: String
        let text: String
        let destination: String
    }

    /// `[text](destination)` and `[text](<destination>)`. Deliberately a narrow
    /// pattern — no nested brackets, no title attribute — because anything more
    /// exotic than what `encode` writes is better handled by the bare scrape than
    /// by a half-correct markdown parser.
    private static func markdownMatches(in line: String) -> [MarkdownMatch] {
        guard line.contains("]("), let regex = try? NSRegularExpression(
            pattern: "\\[([^\\]]*)\\]\\(\\s*<?([^\\s)>]+)>?\\s*\\)")
        else { return [] }
        let range = NSRange(line.startIndex..., in: line)
        return regex.matches(in: line, range: range).compactMap { match in
            guard let whole = Range(match.range, in: line),
                  let text = Range(match.range(at: 1), in: line),
                  let destination = Range(match.range(at: 2), in: line)
            else { return nil }
            return MarkdownMatch(
                whole: String(line[whole]), text: String(line[text]),
                destination: String(line[destination]))
        }
    }

    /// A markdown destination through the same offline unwrap + http(s) gate as
    /// every other imported link, so a `mailto:` link in someone's exported note
    /// is refused and a Facebook shim resolves. Bare hosts are accepted here (a
    /// markdown link's destination is unambiguously a destination — there is no
    /// stray-decimal risk that makes the flat scrape refuse them).
    private static func normalized(_ destination: String) -> String? {
        guard LinkListCSV.isSingleURLCandidate(destination) else { return nil }
        return URLUnwrapper.ingestURL(from: destination, allowBareHost: true)?.absoluteString
    }
}

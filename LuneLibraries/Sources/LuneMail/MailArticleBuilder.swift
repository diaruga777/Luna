//
//  MailArticleBuilder.swift
//  Lune
//

import LuneHTMLClassification
import LuneModels
import Foundation

/// Turns an incoming email into a readable `ArticleContent`: subject → title,
/// sender → author, and the body parsed to blocks (HTML via the readability
/// extractor, else plain-text paragraphs), with common newsletter footers
/// (unsubscribe, view-in-browser, address blocks) trimmed off.
public enum MailArticleBuilder {

    /// Lower-cased markers that indicate the start of footer/boilerplate junk.
    private static let footerMarkers = [
        "unsubscribe", "view this email", "view in browser", "view it in your browser",
        "manage your preferences", "update your preferences", "email preferences",
        "you are receiving this", "you're receiving this", "you received this",
        "no longer wish to receive", "all rights reserved", "©", "copyright ",
        "sent to you by", "this email was sent",
    ]

    /// Builds an article from the message, or nil if there's no usable body.
    public static func article(from message: IncomingMessage) -> ArticleContent? {
        let title = decodeEncodedWords(message.subject).trimmingCharacters(in: .whitespacesAndNewlines)
        let author = senderName(from: message.from)

        // Walk the MIME structure to the richest text part (newsletters carry a
        // base64/quoted-printable text/html part inside multipart/alternative).
        let extracted = MIMEBody.extract(
            rawBody: message.body,
            contentType: message.contentType,
            transferEncoding: message.transferEncoding)
        let decoded = extracted.text

        let blocks: [ArticleContent.Block]
        if extracted.isHTML || looksLikeHTML(decoded) {
            // Reuse the readability extractor; placeholder base URL for relative links.
            let base = URL(string: "https://mail.invalid") ?? URL(fileURLWithPath: "/")
            if let extracted = try? ArticleExtractor().extract(html: decoded, baseURL: base),
               !extracted.blocks.isEmpty {
                blocks = trimFooterBlocks(extracted.blocks)
            } else {
                blocks = paragraphBlocks(from: strippedTags(decoded))
            }
        } else {
            blocks = paragraphBlocks(from: decoded)
        }

        guard blocks.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return nil }
        return ArticleContent(
            title: title.isEmpty ? (author ?? "Email") : title, author: author, blocks: blocks)
    }

    /// Display name from a `From` header (`"Name" <addr>` → `Name`; else the
    /// address local part).
    public static func senderName(from rawFrom: String) -> String? {
        let from = decodeEncodedWords(rawFrom).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty else { return nil }
        if let lt = from.firstIndex(of: "<") {
            let name = from[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if !name.isEmpty { return name }
            // No display name: use the address's local part.
            let rest = from[from.index(after: lt)...]
            if let at = rest.firstIndex(of: "@") { return String(rest[..<at]) }
        }
        if let at = from.firstIndex(of: "@") { return String(from[..<at]) }
        return from
    }

    /// Heuristic: does this body contain HTML markup (vs. plain text)?
    public static func looksLikeHTML(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.contains("<html") || lower.contains("<body") || lower.contains("<div")
            || lower.contains("<table") || lower.contains("<p>") || lower.contains("<p ")
    }

    /// Splits plain text into paragraph blocks, dropping everything from the
    /// first footer marker onward and any signature (`-- ` line).
    public static func paragraphBlocks(from text: String) -> [ArticleContent.Block] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if let cut = lines.firstIndex(where: { line in
            let l = line.lowercased()
            return line == "-- " || footerMarkers.contains { l.contains($0) }
        }) {
            lines = Array(lines.prefix(cut))
        }
        // Group consecutive non-blank lines into paragraphs.
        var paragraphs: [String] = []
        var current = ""
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { paragraphs.append(current); current = "" }
            } else {
                current += current.isEmpty ? line : " " + line.trimmingCharacters(in: .whitespaces)
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { ArticleContent.Block(kind: .paragraph, text: $0, links: []) }
    }

    /// Drops trailing blocks once a footer marker appears — but only in the
    /// latter part of the article, so an early "©"/"unsubscribe" (e.g. in a
    /// masthead) doesn't nuke the whole body. Keeps everything if the only
    /// markers are near the top, or if trimming would drop most of the content.
    public static func trimFooterBlocks(_ blocks: [ArticleContent.Block]) -> [ArticleContent.Block] {
        guard blocks.count > 4 else { return blocks }
        let earliestTrimmable = blocks.count / 2
        if let cut = blocks.indices.first(where: { index in
            guard index >= earliestTrimmable else { return false }
            let l = blocks[index].text.lowercased()
            return footerMarkers.contains { l.contains($0) }
        }) {
            return Array(blocks.prefix(cut))
        }
        return blocks
    }

    /// Very small tag stripper for the HTML-extractor fallback path.
    public static func strippedTags(_ html: String) -> String {
        var result = ""
        var insideTag = false
        for char in html {
            if char == "<" { insideTag = true }
            else if char == ">" { insideTag = false }
            else if !insideTag { result.append(char) }
        }
        return result
    }

    /// Decodes RFC 2047 encoded-words (`=?charset?B/Q?text?=`) in a header value.
    public static func decodeEncodedWords(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        var result = value
        while let start = result.range(of: "=?"),
              let end = result.range(of: "?=", range: start.upperBound..<result.endIndex) {
            let token = String(result[result.index(start.lowerBound, offsetBy: 2)..<end.lowerBound])
            let parts = token.split(separator: "?", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { break }
            let encoding = parts[1].uppercased()
            let payload = String(parts[2])
            var decoded = payload
            if encoding == "B", let data = Data(base64Encoded: payload) {
                decoded = String(decoding: data, as: UTF8.self)
            } else if encoding == "Q" {
                decoded = GmailIMAPClient.decodeQuotedPrintable(
                    payload.replacingOccurrences(of: "_", with: " "))
            }
            result.replaceSubrange(start.lowerBound..<end.upperBound, with: decoded)
        }
        return result
    }
}

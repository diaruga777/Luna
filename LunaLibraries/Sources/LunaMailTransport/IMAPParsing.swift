//
//  IMAPParsing.swift
//  Luna
//

import Foundation

/// One incoming message fetched from IMAP.
public struct IncomingMessage: Equatable {
    public let uid: Int
    public let from: String
    public let subject: String
    public let date: String
    /// Top-level `Content-Type` (carries the multipart boundary, if any).
    public let contentType: String
    /// Top-level `Content-Transfer-Encoding` (base64 / quoted-printable / …).
    public let transferEncoding: String
    public let body: String
    /// URLs detected in the body (plain text + any HTML hrefs).
    public let urls: [URL]

    public init(uid: Int, from: String, subject: String, date: String, contentType: String,
                transferEncoding: String, body: String, urls: [URL]) {
        self.uid = uid
        self.from = from
        self.subject = subject
        self.date = date
        self.contentType = contentType
        self.transferEncoding = transferEncoding
        self.body = body
        self.urls = urls
    }
}

/// The pure IMAP/RFC822 parsing helpers shared by `StreamIMAPClient` (the live
/// transport), `MIMEBody`, and the mail importer. Nothing here talks to a
/// server, and nothing here is Gmail-specific — the name is kept because every
/// call site spells it.
public enum GmailIMAPClient {

    /// IMAP quoted string (wraps in quotes, escapes `\` and `"`).
    public static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Trailing `{123}` literal byte count at the end of a line, if present.
    public static func trailingLiteralCount(_ line: String) -> Int? {
        guard line.hasSuffix("}"), let open = line.lastIndex(of: "{") else { return nil }
        let digits = line[line.index(after: open)..<line.index(before: line.endIndex)]
        return Int(digits)
    }

    /// Extracts a `[KEY value]` integer from SELECT response lines.
    public static func parseBracketValue(_ key: String, in lines: [String]) -> Int? {
        for line in lines {
            guard let range = line.range(of: "[\(key) ") else { continue }
            let rest = line[range.upperBound...]
            let digits = rest.prefix { $0.isNumber }
            if let value = Int(digits) { return value }
        }
        return nil
    }

    /// UIDs from an untagged `* SEARCH 1 2 3` line.
    public static func parseSearchUIDs(_ lines: [String]) -> [Int] {
        for line in lines {
            let upper = line.uppercased()
            guard upper.hasPrefix("* SEARCH") else { continue }
            return line.split(separator: " ").compactMap { Int($0) }
        }
        return []
    }

    /// New UIDs from a `* SEARCH` response, keeping only those strictly greater
    /// than `afterUID`. IMAP `UID SEARCH UID N:*` returns the highest existing
    /// UID even when it's below N — the range `N:*` is order-independent and `*`
    /// is the last message — so without this filter the newest message would
    /// re-import on every poll.
    public static func newSearchUIDs(_ lines: [String], afterUID: Int) -> [Int] {
        parseSearchUIDs(lines).filter { $0 > afterUID }
    }

    /// Splits a raw RFC822 message into its top-level header block and body at
    /// the first blank line (CRLFCRLF, or LFLF as a fallback).
    public static func splitMessage(_ raw: String) -> (headers: String, body: String) {
        if let range = raw.range(of: "\r\n\r\n") {
            return (String(raw[..<range.lowerBound]), String(raw[range.upperBound...]))
        }
        if let range = raw.range(of: "\n\n") {
            return (String(raw[..<range.lowerBound]), String(raw[range.upperBound...]))
        }
        return (raw, "")
    }

    /// Parses `Key: value` headers (lowercased keys; unfolds simple folds).
    public static func parseHeaders(_ raw: String) -> [String: String] {
        var headers: [String: String] = [:]
        var currentKey: String?
        for rawLine in raw.replacingOccurrences(of: "\r\n", with: "\n").split(
            separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let first = line.first, first == " " || first == "\t", let key = currentKey {
                headers[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
                currentKey = key
            }
        }
        return headers
    }

    /// URLs in a message body: plain-text links via NSDataDetector plus any
    /// `href` targets in HTML. Gmail bodies are usually quoted-printable, where
    /// soft line breaks (`=\r\n`) split long URLs and `=XX` escapes hide chars;
    /// when we detect QP we decode the whole body first (in a true QP body any
    /// literal `=` is itself encoded, so a full decode is safe).
    public static func extractURLs(from body: String) -> [URL] {
        let text = (body.contains("=\r\n") || body.contains("=\n") || body.contains("=3D"))
            ? decodeQuotedPrintable(body) : body

        var found: [URL] = []
        var seen = Set<String>()
        func add(_ string: String) {
            let candidate = string.trimmingCharacters(
                in: CharacterSet(charactersIn: "\"'<>) \t\r\n"))
            guard let url = URL(string: candidate), url.scheme?.hasPrefix("http") == true,
                  seen.insert(url.absoluteString).inserted else { return }
            found.append(url)
        }
        if let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let url = match.url { add(url.absoluteString) }
            }
        }
        // hrefs (links the detector may miss).
        var searchRange = text.startIndex..<text.endIndex
        while let hrefRange = text.range(of: "href=", options: .caseInsensitive, range: searchRange) {
            let after = text[hrefRange.upperBound...]
            let quote = after.first
            let valueStart = (quote == "\"" || quote == "'")
                ? after.index(after: after.startIndex) : after.startIndex
            let terminators: Set<Character> = quote == "\"" ? ["\""]
                : quote == "'" ? ["'"] : [" ", ">", "\r", "\n"]
            let end = text[valueStart...].firstIndex { terminators.contains($0) } ?? text.endIndex
            add(String(text[valueStart..<end]))
            searchRange = end..<text.endIndex
        }
        return found
    }

    /// Decodes a quoted-printable string: drops soft line breaks and turns `=XX`
    /// hex escapes back into bytes (decoded as UTF-8). Iterates Unicode scalars,
    /// not Characters — Swift clusters `\r\n` into one Character, which would
    /// hide the soft break.
    public static func decodeQuotedPrintable(_ s: String) -> String {
        var bytes: [UInt8] = []
        let scalars = Array(s.unicodeScalars)
        let cr = Unicode.Scalar(13), lf = Unicode.Scalar(10), eq = Unicode.Scalar(61)
        var i = 0
        func hex(_ scalar: Unicode.Scalar) -> UInt8? { UInt8(String(scalar), radix: 16) }
        while i < scalars.count {
            if scalars[i] == eq {
                if i + 1 < scalars.count, scalars[i + 1] == lf { i += 2; continue }
                if i + 2 < scalars.count, scalars[i + 1] == cr, scalars[i + 2] == lf { i += 3; continue }
                if i + 2 < scalars.count, let hi = hex(scalars[i + 1]), let lo = hex(scalars[i + 2]) {
                    bytes.append(hi << 4 | lo); i += 3; continue
                }
            }
            bytes.append(contentsOf: Array(String(scalars[i]).utf8))
            i += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

}

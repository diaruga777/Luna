//
//  MIMEBody.swift
//  Clip
//

import Foundation

/// Extracts the best readable text out of an email body. Newsletters are almost
/// always `multipart/alternative` (or `multipart/mixed`) carrying a base64- or
/// quoted-printable-encoded `text/html` part — a raw `BODY[TEXT]` fetch returns
/// that whole MIME blob, which must be walked to find and decode the real
/// content. For a single-part message it just applies the transfer-encoding.
enum MIMEBody {

    /// The decoded body and whether it is HTML.
    struct Extracted: Equatable {
        let text: String
        let isHTML: Bool
    }

    /// Walks `rawBody` using the top-level `contentType` / `transferEncoding`
    /// headers and returns the richest part (prefers `text/html`, then
    /// `text/plain`). Falls back to the decoded raw body when there's no usable
    /// MIME structure.
    static func extract(rawBody: String, contentType: String, transferEncoding: String) -> Extracted {
        let parsed = parse(rawBody: rawBody, contentType: contentType, transferEncoding: transferEncoding)
        if let parsed { return parsed }
        // No MIME structure recognized: decode by the top-level encoding and
        // guess HTML from the content.
        let decoded = decode(rawBody, transferEncoding: transferEncoding)
        return Extracted(text: decoded, isHTML: looksLikeHTML(decoded))
    }

    // MARK: - Recursive part walk

    private static func parse(rawBody: String, contentType: String, transferEncoding: String) -> Extracted? {
        let type = contentType.lowercased()

        // A forwarded-as-attachment email: the part body is a full nested
        // message (its own headers + body). Recurse into it.
        if type.contains("message/rfc822") {
            let decoded = decode(rawBody, transferEncoding: transferEncoding)
            if let (headers, body) = splitHeaders(decoded) {
                return parse(
                    rawBody: body,
                    contentType: headers["content-type"] ?? "text/plain",
                    transferEncoding: headers["content-transfer-encoding"] ?? "7bit")
            }
        }

        guard type.contains("multipart/"), let boundary = boundary(in: contentType) else {
            // A leaf part.
            let decoded = decode(rawBody, transferEncoding: transferEncoding)
            if type.contains("text/html") { return Extracted(text: decoded, isHTML: true) }
            if type.contains("text/plain") { return Extracted(text: decoded, isHTML: false) }
            return nil
        }

        var html: Extracted?
        var plain: Extracted?
        for part in split(rawBody, boundary: boundary) {
            guard let (headers, body) = splitHeaders(part) else { continue }
            let partType = headers["content-type"] ?? "text/plain"
            let partEncoding = headers["content-transfer-encoding"] ?? "7bit"
            guard let extracted = parse(rawBody: body, contentType: partType, transferEncoding: partEncoding)
            else { continue }
            if extracted.isHTML { if html == nil { html = extracted } }
            else if plain == nil { plain = extracted }
        }
        return html ?? plain
    }

    /// Splits a multipart body on `--boundary` delimiters, dropping the preamble
    /// and the closing `--boundary--` epilogue.
    private static func split(_ body: String, boundary: String) -> [String] {
        let delimiter = "--" + boundary
        let segments = body.components(separatedBy: delimiter)
        // First segment is the preamble (before the first boundary); the final
        // closing boundary leaves a trailing "--…" segment we ignore.
        return segments.dropFirst().compactMap { segment in
            let trimmed = segment.hasPrefix("--") ? nil : segment
            return trimmed
        }
    }

    /// Splits a part into its (lowercased-key) headers and its body. A blank
    /// line separates them.
    private static func splitHeaders(_ part: String) -> (headers: [String: String], body: String)? {
        let normalized = part.replacingOccurrences(of: "\r\n", with: "\n")
        // Drop a single leading newline left by the boundary split.
        let trimmed = normalized.hasPrefix("\n") ? String(normalized.dropFirst()) : normalized
        guard let separator = trimmed.range(of: "\n\n") else {
            return ([:], trimmed)
        }
        let headerText = String(trimmed[..<separator.lowerBound])
        let body = String(trimmed[separator.upperBound...])
        var headers: [String: String] = [:]
        var currentKey: String?
        for line in headerText.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first == " " || first == "\t", let key = currentKey {
                headers[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                currentKey = key
            }
        }
        return (headers, body)
    }

    /// The `boundary=` parameter from a Content-Type header (quoted or bare).
    static func boundary(in contentType: String) -> String? {
        guard let range = contentType.range(of: "boundary=", options: .caseInsensitive) else { return nil }
        var value = String(contentType[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") {
            value.removeFirst()
            if let end = value.firstIndex(of: "\"") { value = String(value[..<end]) }
        } else if let end = value.firstIndex(where: { $0 == ";" || $0 == " " }) {
            value = String(value[..<end])
        }
        return value.isEmpty ? nil : value
    }

    /// Decodes a part body by its Content-Transfer-Encoding (base64 /
    /// quoted-printable; otherwise returned as-is).
    static func decode(_ body: String, transferEncoding: String) -> String {
        switch transferEncoding.lowercased().trimmingCharacters(in: .whitespaces) {
        case "base64":
            let stripped = body.components(separatedBy: .whitespacesAndNewlines).joined()
            if let data = Data(base64Encoded: stripped) {
                return String(decoding: data, as: UTF8.self)
            }
            return body
        case "quoted-printable":
            return GmailIMAPClient.decodeQuotedPrintable(body)
        default:
            return body
        }
    }

    private static func looksLikeHTML(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.contains("<html") || lower.contains("<body") || lower.contains("<div")
            || lower.contains("<table") || lower.contains("<p>") || lower.contains("<p ")
    }
}

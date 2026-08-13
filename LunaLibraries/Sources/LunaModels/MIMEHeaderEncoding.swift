//
//  MIMEHeaderEncoding.swift
//  LunaModels
//
//  Shared by LunaMailAccount's two MIME builders (MIMEMessage for send-to-Kindle
//  and EmailMIMEBuilder for shares), and by anything else that assembles a mail
//  header. Header text must respect RFC 5322's 998-octet line limit — strict
//  servers reject or mangle over-long header lines — and RFC 2047's 75-char
//  encoded-word limit for non-ASCII text.
//

import Foundation

public enum MIMEHeaderEncoding {

    /// Conservative maximum octets per header line (well under RFC 5322's 998).
    static let maxLineLength = 76

    /// Encodes unstructured header text (Subject etc.): short plain ASCII
    /// passes through; long plain ASCII folds at spaces; non-ASCII becomes a
    /// sequence of RFC 2047 B-encoded words on folded continuation lines
    /// (decoders rejoin adjacent encoded words without the folding space).
    public static func encodedHeaderText(_ text: String) -> String {
        let isPlainASCII = text.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value < 127 }
        guard isPlainASCII else { return encodedWords(text) }
        return foldAtSpaces(text)
    }

    /// Folds an over-long header VALUE that contains no foldable spaces (e.g.
    /// an unbroken base64 blob like X-Luna-Share) by inserting CRLF+SP at a
    /// fixed width. Unfolding leaves a space behind, so this is only correct
    /// for consumers that strip whitespace before decoding (LunaShareMarker
    /// does). Values already short enough pass through unchanged.
    public static func foldedRawValue(_ value: String) -> String {
        guard value.count > maxLineLength else { return value }
        var lines: [String] = []
        var remainder = Substring(value)
        while !remainder.isEmpty {
            let line = remainder.prefix(maxLineLength)
            lines.append(String(line))
            remainder = remainder.dropFirst(line.count)
        }
        return lines.joined(separator: "\r\n ")
    }

    /// RFC 5322 date header value.
    public static func rfc5322Date(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    // MARK: - Private

    private static func foldAtSpaces(_ text: String) -> String {
        guard text.count > maxLineLength else { return text }
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= maxLineLength {
                current += " " + word
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.joined(separator: "\r\n ")
    }

    /// Splits into ≤42-byte UTF-8 chunks on character boundaries — each
    /// B-encodes to a ≤68-char word, within RFC 2047's 75-char cap.
    private static func encodedWords(_ text: String) -> String {
        let maxChunkBytes = 42
        var words: [String] = []
        var chunk = ""
        var chunkBytes = 0
        for character in text {
            let bytes = String(character).utf8.count
            if chunkBytes + bytes > maxChunkBytes, !chunk.isEmpty {
                words.append(encodedWord(chunk))
                chunk = ""
                chunkBytes = 0
            }
            chunk.append(character)
            chunkBytes += bytes
        }
        if !chunk.isEmpty { words.append(encodedWord(chunk)) }
        return words.joined(separator: "\r\n ")
    }

    private static func encodedWord(_ chunk: String) -> String {
        "=?UTF-8?B?\(Data(chunk.utf8).base64EncodedString())?="
    }
}

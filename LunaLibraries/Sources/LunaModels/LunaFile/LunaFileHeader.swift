//
//  LunaFileHeader.swift
//  LunaModels
//

import Foundation

/// Limits every Luna file shares, whatever its marker.
public enum LunaFileLimits {
    /// The largest Luna file any surface reads. Safari's message channel caps a
    /// served plugin source at 1.5 MB, so a larger file could never run in every
    /// process that is supposed to run it.
    public static let maxSourceKB = 1024
}

/// The first header line of a Luna file. It names the format of everything
/// after the header comment (`claudedocs/luna-file.md`).
public enum LunaFileMarker: String, Equatable, Sendable, CaseIterable {
    /// The body is JavaScript: a plugin draft.
    case plugin = "luna-plugin"
    /// The body is one JSON object: a recovered save.
    case recovery = "luna-recovery"
}

/// The leading `/* <marker> … */` comment every Luna file opens with, split
/// into the marker, the JSON the comment holds, and the text below it.
///
/// The shape is one specification with two readers: `PluginManifestParser`
/// reads a `luna-plugin` header, `LunaRecoveryFile` a `luna-recovery` one.
/// Only the FIRST `*/` closes the header, so a body may hold one of its own.
///
/// Line numbers are kept so an error can name the line an author must fix.
public struct LunaFileHeader: Equatable, Sendable {
    public let marker: LunaFileMarker
    /// The JSON text between the marker line and the closing `*/`.
    public let json: String
    /// Everything after the closing `*/`.
    public let body: String
    /// 1-based line of the opening `/*`.
    public let commentStartLine: Int
    /// 1-based line the JSON object starts on.
    public let jsonStartLine: Int
    /// The JSON's lines, for locating one field.
    public let jsonLines: [String]
    /// 1-based line the body starts on — the line carrying the closing `*/`.
    public let bodyStartLine: Int

    public init(
        marker: LunaFileMarker, json: String, body: String,
        commentStartLine: Int, jsonStartLine: Int, jsonLines: [String],
        bodyStartLine: Int
    ) {
        self.marker = marker
        self.json = json
        self.body = body
        self.commentStartLine = commentStartLine
        self.jsonStartLine = jsonStartLine
        self.jsonLines = jsonLines
        self.bodyStartLine = bodyStartLine
    }

    /// The line a field is written on, or the JSON's first line when the field
    /// is absent.
    public func line(of field: String) -> Int {
        let needle = "\"\(field)\""
        for (offset, text) in jsonLines.enumerated() where text.contains(needle) {
            return jsonStartLine + offset
        }
        return jsonStartLine
    }

    /// Reads the header of `text`, or says what stopped it.
    ///
    /// The first non-whitespace token must be `/*`. The comment's first line,
    /// trimmed, must equal a `LunaFileMarker` exactly — a near miss such as
    /// `luna-plugin-evil` is not a Luna file.
    public static func parse(_ text: String) -> Result<LunaFileHeader, LunaFileError> {
        guard text.utf8.count <= LunaFileLimits.maxSourceKB * 1024 else {
            return .failure(.fileTooLarge(limitKB: LunaFileLimits.maxSourceKB))
        }
        var index = text.startIndex
        var line = 1
        while index < text.endIndex, text[index].isWhitespace {
            if text[index] == "\n" { line += 1 }
            index = text.index(after: index)
        }
        guard text[index...].hasPrefix("/*") else { return .failure(.noHeader) }
        let commentStartLine = line
        let commentStart = text.index(index, offsetBy: 2)
        guard let close = text.range(of: "*/", range: commentStart..<text.endIndex) else {
            return .failure(.noHeader)
        }
        let comment = String(text[commentStart..<close.lowerBound])
        var commentLines = comment.components(separatedBy: "\n")
        guard let first = commentLines.first else { return .failure(.noHeader) }
        let markerText = first.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let marker = LunaFileMarker(rawValue: markerText) else {
            return .failure(.noHeader)
        }
        commentLines.removeFirst()
        // The JSON is everything after the marker line. A leading `{` on the
        // marker line itself is not supported: the marker names the format, and
        // the object below it is what an author reads.
        let json = commentLines.joined(separator: "\n")
        guard json.contains("{") else {
            return .failure(.headerNotJSON(
                line: commentStartLine + 1, detail: "the header holds no { … } object"))
        }
        return .success(LunaFileHeader(
            marker: marker, json: json, body: String(text[close.upperBound...]),
            commentStartLine: commentStartLine, jsonStartLine: commentStartLine + 1,
            jsonLines: commentLines,
            bodyStartLine: commentStartLine + comment.filter { $0 == "\n" }.count))
    }

    /// The header JSON as a dictionary, or the error naming the line.
    public func jsonObject() -> Result<[String: Any], LunaFileError> {
        do {
            let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [])
            guard let dictionary = parsed as? [String: Any] else {
                return .failure(.headerNotJSON(
                    line: jsonStartLine, detail: "the header is not a { … } object"))
            }
            return .success(dictionary)
        } catch {
            return .failure(.headerNotJSON(line: jsonStartLine, detail: error.localizedDescription))
        }
    }
}

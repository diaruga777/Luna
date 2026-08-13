//
//  ShareTextURL.swift
//  Luna
//

import Foundation

/// Decides whether shared text (a string or a .txt file's contents) is really
/// "just a link" — either the whole thing is one URL plus whitespace/punctuation,
/// or it's short and starts with a URL. In those cases the URL is what should be
/// imported and the rest dropped. Pure, so it's testable.
public enum ShareTextURL {
    /// Text no longer than this still counts as "short" for the starts-with-URL rule.
    public static let shortTextLimit = 200

    public static func extract(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let detector = try? NSDataDetector(
                types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }

        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = detector.firstMatch(in: trimmed, range: range),
              let url = match.url, url.absoluteString.hasPrefix("http"),
              let matchRange = Range(match.range, in: trimmed)
        else { return nil }

        // Case A: only the URL remains once whitespace/punctuation is removed.
        let withoutURL = trimmed.replacingCharacters(in: matchRange, with: "")
        if withoutURL.unicodeScalars.allSatisfy(Self.isTrivial) { return url }

        // Case B: short text that begins with the URL (only trivia before it).
        let prefix = trimmed[trimmed.startIndex..<matchRange.lowerBound]
        if trimmed.count <= shortTextLimit, prefix.unicodeScalars.allSatisfy(Self.isTrivial) {
            return url
        }
        return nil
    }

    /// The link inside text a host handed over INSTEAD of a URL — looser than
    /// `extract`, and only for that case.
    ///
    /// `extract` answers "is this text just a link?", the right question for a
    /// shared text FILE (a note that mentions a link is a note). A share sheet
    /// payload is different: a host that shares a link as text commonly captions
    /// it — the YouTube share sheet sends `<video title>\n<link>` — and there the
    /// link IS the share; importing the caption as a text document instead loses
    /// it. So this accepts a link with prose around it, as long as everything
    /// that ISN'T the link stays within `captionLimit`. Longer surrounding text is
    /// a genuine text share and returns nil, keeping the document import.
    public static func firstLink(in text: String, captionLimit: Int = shortTextLimit) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let detector = try? NSDataDetector(
                types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }

        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = detector.firstMatch(in: trimmed, range: range),
              let url = match.url, url.absoluteString.hasPrefix("http"),
              let matchRange = Range(match.range, in: trimmed)
        else { return nil }

        let caption = trimmed.replacingCharacters(in: matchRange, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return caption.count <= captionLimit ? url : nil
    }

    private static func isTrivial(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar)
            || CharacterSet.punctuationCharacters.contains(scalar)
    }
}

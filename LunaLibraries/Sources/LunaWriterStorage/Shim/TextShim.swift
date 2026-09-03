// Shim: delete when LunaWriterText merges.
//
// `claudedocs/plans/writer-app.md` §4 puts these four in LunaWriterText, which
// is written in parallel. Only the members this tier calls are present, with
// the plan's signatures, so the swap is an import.

import Foundation
import NaturalLanguage

/// Web-Annotation style anchoring: exact offsets first, then quote plus
/// context, then a bounded fuzzy search.
struct TextAnchorResolver {
    /// How far from the recorded offset a re-anchor looks.
    static let searchRadius = 2_000
    static let maximumExactLength = 512
    static let maximumContextLength = 32

    init() {}

    func make(range: NSRange, in text: String) -> TextAnchor {
        let string = text as NSString
        let clamped = TextAnchorResolver.clamp(range, to: string.length)
        let exact = string.substring(with: clamped)
        let prefixStart = max(0, clamped.location - TextAnchorResolver.maximumContextLength)
        let prefix = string.substring(with: NSRange(
            location: prefixStart, length: clamped.location - prefixStart))
        let suffixStart = clamped.location + clamped.length
        let suffixLength = min(TextAnchorResolver.maximumContextLength, string.length - suffixStart)
        let suffix = string.substring(with: NSRange(location: suffixStart, length: suffixLength))
        return TextAnchor(
            start: clamped.location, end: clamped.location + clamped.length,
            exact: String(exact.prefix(TextAnchorResolver.maximumExactLength)),
            prefix: prefix, suffix: suffix)
    }

    func resolve(_ anchor: TextAnchor, in text: String) -> NSRange? {
        let string = text as NSString
        let length = anchor.end - anchor.start
        guard length >= 0 else { return nil }
        let recorded = NSRange(location: anchor.start, length: length)
        if NSMaxRange(recorded) <= string.length, string.substring(with: recorded) == anchor.exact {
            return recorded
        }
        guard !anchor.exact.isEmpty else { return nil }
        let window = TextAnchorResolver.window(around: anchor.start, in: string)
        if let withContext = TextAnchorResolver.nearest(
            anchor.prefix + anchor.exact + anchor.suffix, in: string, window: window,
            to: anchor.start) {
            return NSRange(
                location: withContext.location + (anchor.prefix as NSString).length,
                length: (anchor.exact as NSString).length)
        }
        return TextAnchorResolver.nearest(anchor.exact, in: string, window: window, to: anchor.start)
    }

    private static func window(around offset: Int, in string: NSString) -> NSRange {
        let start = max(0, min(offset, string.length) - searchRadius)
        let end = min(string.length, min(offset, string.length) + searchRadius)
        return NSRange(location: start, length: max(0, end - start))
    }

    /// The occurrence of `needle` inside `window` whose start is closest to
    /// `target`, so a re-anchor follows the nearest copy rather than the first.
    private static func nearest(
        _ needle: String, in string: NSString, window: NSRange, to target: Int
    ) -> NSRange? {
        guard !needle.isEmpty else { return nil }
        var best: NSRange?
        var searchFrom = window.location
        while searchFrom < NSMaxRange(window) {
            let remaining = NSRange(
                location: searchFrom, length: NSMaxRange(window) - searchFrom)
            let found = string.range(of: needle, options: [], range: remaining)
            guard found.location != NSNotFound else { break }
            if best == nil || abs(found.location - target) < abs(best!.location - target) {
                best = found
            }
            searchFrom = found.location + 1
        }
        return best
    }

    private static func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let location = max(0, min(range.location, length))
        return NSRange(location: location, length: max(0, min(range.length, length - location)))
    }
}

/// The title and list snippet a document shows, read out of its Markdown.
enum TitleDeriver {
    static func title(of text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("#") {
                let stripped = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !stripped.isEmpty { return stripped }
                continue
            }
            return stripMarkup(trimmed)
        }
        return L10nWriterStorage.untitledDocumentTitle
    }

    static func snippet(of text: String, limit: Int = 160) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines = lines.dropFirst()
        }
        lines = lines.dropFirst()
        let body = lines
            .map { stripMarkup($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(body.prefix(limit))
    }

    private static func stripMarkup(_ line: String) -> String {
        var result = line
        for marker in ["**", "__", "==", "~~", "`", "*", "_", ">"] {
            result = result.replacingOccurrences(of: marker, with: "")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

/// Sentence ranges inside a paragraph, used here to pack a long capture.
struct SentenceSegmenter {
    init() {}

    func sentences(in paragraph: NSRange, of text: String) -> [NSRange] {
        let string = text as NSString
        let clamped = NSIntersectionRange(paragraph, NSRange(location: 0, length: string.length))
        guard clamped.length > 0 else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var ranges: [NSRange] = []
        guard let swiftRange = Range(clamped, in: text) else { return [] }
        tokenizer.enumerateTokens(in: swiftRange) { range, _ in
            ranges.append(NSRange(range, in: text))
            return true
        }
        return ranges.isEmpty ? [clamped] : ranges
    }

    func sentenceRange(containing offset: Int, in text: String) -> NSRange? {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        return sentences(in: whole, of: text).first { NSLocationInRange(offset, $0) }
    }
}

/// Word and character counts for a document or a selection.
enum TextStatistics {
    struct Stats: Equatable {
        var words: Int
        var characters: Int
        var charactersWithoutSpaces: Int
        var sentences: Int
        var paragraphs: Int
        var readingMinutes: Double
    }

    /// Words per minute used for the reading estimate.
    static let readingWordsPerMinute = 238.0

    static func measure(_ text: String, range: NSRange? = nil) -> Stats {
        let string = text as NSString
        let scope = range.map {
            NSIntersectionRange($0, NSRange(location: 0, length: string.length))
        } ?? NSRange(location: 0, length: string.length)
        let slice = string.substring(with: scope)
        let words = slice.split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "-" }.count
        let paragraphs = slice
            .components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
        let sentences = SentenceSegmenter()
            .sentences(in: NSRange(location: 0, length: (slice as NSString).length), of: slice)
            .count
        return Stats(
            words: words,
            characters: slice.count,
            charactersWithoutSpaces: slice.filter { !$0.isWhitespace }.count,
            sentences: sentences,
            paragraphs: paragraphs,
            readingMinutes: Double(words) / readingWordsPerMinute)
    }
}

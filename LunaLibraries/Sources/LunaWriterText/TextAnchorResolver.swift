import Foundation
import LunaWriterModels

/// Turns a range into an anchor that survives editing, and finds it again.
///
/// Three tiers, tried in order: the saved offsets when the text there still
/// reads the same; the quote with its context, then the quote alone, within
/// a window around the old offsets, and a single whole-document match of the
/// quote with its context; then an approximate match of the quote.
/// Nothing found means the anchor is orphaned, and the caller says so rather
/// than pointing a note at the wrong sentence.
public enum TextAnchorResolver {

    /// How far either side of the old offsets the search looks.
    static let searchWindow = 2000
    /// The share of the quote that may differ and still count as a match.
    static let fuzzyTolerance = 0.1
    /// Longer quotes match on their head, to keep the match affordable.
    static let fuzzyPatternLimit = 256
    static let candidateLimit = 16

    // MARK: - Making

    public static func make(range: NSRange, in text: NSString) -> TextAnchor {
        let clamped = clamp(range, to: text.length)
        let exact = cappedText(of: clamped, in: text)
        let prefixStart = max(0, clamped.location - TextAnchor.contextLimit)
        let prefix = text.substring(with: NSRange(location: prefixStart, length: clamped.location - prefixStart))
        let suffixEnd = min(text.length, NSMaxRange(clamped) + TextAnchor.contextLimit)
        let suffix = text.substring(with: NSRange(location: NSMaxRange(clamped), length: suffixEnd - NSMaxRange(clamped)))
        return TextAnchor(
            start: clamped.location,
            end: NSMaxRange(clamped),
            exact: exact,
            prefix: prefix,
            suffix: suffix)
    }

    // MARK: - Resolving

    public static func resolve(_ anchor: TextAnchor, in text: NSString) -> NSRange? {
        let exact = anchor.exact as NSString
        guard exact.length > 0 else {
            return anchor.start >= 0 && anchor.start <= text.length
                ? NSRange(location: anchor.start, length: 0) : nil
        }
        let originalLength = max(exact.length, anchor.end - anchor.start)

        // Tier one: the offsets still hold the same text.
        let saved = NSRange(location: anchor.start, length: max(0, anchor.end - anchor.start))
        if saved.location >= 0, NSMaxRange(saved) <= text.length, cappedText(of: saved, in: text) == anchor.exact {
            return saved
        }

        let window = self.window(around: anchor, in: text)
        guard window.length > 0 else { return nil }

        // Tier two: the quote with its context, then the quote alone.
        let context = anchor.prefix + anchor.exact + anchor.suffix
        if !anchor.prefix.isEmpty || !anchor.suffix.isEmpty,
           let hit = nearestOccurrence(of: context, in: text, window: window, to: anchor.start) {
            let start = hit + (anchor.prefix as NSString).length
            return NSRange(location: start, length: min(originalLength, text.length - start))
        }
        if let hit = nearestOccurrence(of: anchor.exact, in: text, window: window, to: anchor.start) {
            return NSRange(location: hit, length: min(originalLength, text.length - hit))
        }

        // A big edit above can push the quote past the window. Its quote and
        // context together are specific, so one match in the whole document
        // is still the same place.
        if !anchor.prefix.isEmpty || !anchor.suffix.isEmpty {
            let whole = NSRange(location: 0, length: text.length)
            let all = occurrences(of: context, in: text, window: whole, limit: 2)
            if all.count == 1 {
                let start = all[0] + (anchor.prefix as NSString).length
                return NSRange(location: start, length: min(originalLength, text.length - start))
            }
        }

        // Tier three: the quote as it now reads, near where it was.
        return fuzzyMatch(anchor, in: text, window: window)
    }

    // MARK: - Search

    private static func window(around anchor: TextAnchor, in text: NSString) -> NSRange {
        let start = max(0, min(anchor.start, text.length) - searchWindow)
        let end = min(text.length, max(anchor.end, 0) + searchWindow)
        return NSRange(location: start, length: max(0, end - start))
    }

    private static func nearestOccurrence(of needle: String, in text: NSString, window: NSRange, to target: Int) -> Int? {
        var best: Int?
        for hit in occurrences(of: needle, in: text, window: window) {
            if best == nil || abs(hit - target) < abs(best! - target) { best = hit }
        }
        return best
    }

    private static func occurrences(of needle: String, in text: NSString, window: NSRange, limit: Int = 64) -> [Int] {
        guard !needle.isEmpty else { return [] }
        var out: [Int] = []
        var search = window
        while search.length > 0, out.count < limit {
            let found = text.range(of: needle, options: [], range: search)
            guard found.location != NSNotFound else { break }
            out.append(found.location)
            let next = found.location + 1
            guard next < NSMaxRange(window) else { break }
            search = NSRange(location: next, length: NSMaxRange(window) - next)
        }
        return out
    }

    private static func fuzzyMatch(_ anchor: TextAnchor, in text: NSString, window: NSRange) -> NSRange? {
        let exact = anchor.exact as NSString
        let patternLength = min(exact.length, fuzzyPatternLimit)
        var pattern = [unichar](repeating: 0, count: patternLength)
        exact.getCharacters(&pattern, range: NSRange(location: 0, length: patternLength))
        let tolerance = max(1, Int(Double(patternLength) * fuzzyTolerance))

        var candidates: [Int] = []
        func add(_ value: Int) {
            guard value >= window.location, value <= NSMaxRange(window), !candidates.contains(value) else { return }
            candidates.append(value)
        }
        add(anchor.start)
        if !anchor.prefix.isEmpty {
            let prefixLength = (anchor.prefix as NSString).length
            for hit in occurrences(of: anchor.prefix, in: text, window: window, limit: 8) { add(hit + prefixLength) }
        }
        if !anchor.suffix.isEmpty {
            for hit in occurrences(of: anchor.suffix, in: text, window: window, limit: 8) { add(hit - (anchor.end - anchor.start)) }
        }
        let probeLength = min(patternLength, 16)
        let probe = exact.substring(to: probeLength)
        for hit in occurrences(of: probe, in: text, window: window, limit: 8) { add(hit) }

        var best: (range: NSRange, distance: Int)?
        for candidate in candidates.prefix(candidateLimit) {
            guard let match = approximateMatch(pattern: pattern, in: text, from: candidate,
                                               limit: NSMaxRange(window), maxDistance: tolerance) else { continue }
            if best == nil || match.distance < best!.distance {
                best = (NSRange(location: candidate, length: match.length), match.distance)
            }
        }
        guard let winner = best else { return nil }
        let tail = max(0, (anchor.end - anchor.start) - patternLength)
        let length = min(winner.range.length + tail, text.length - winner.range.location)
        return NSRange(location: winner.range.location, length: length)
    }

    /// Edit distance from `pattern` to the text starting at `start`, with the
    /// end free: the answer is the best length to read, and how far off it is.
    private static func approximateMatch(
        pattern: [unichar], in text: NSString, from start: Int, limit: Int, maxDistance: Int
    ) -> (length: Int, distance: Int)? {
        guard start >= 0, start < limit else { return nil }
        let rows = pattern.count
        let columns = min(rows + maxDistance, limit - start)
        guard columns > 0 else { return nil }
        var window = [unichar](repeating: 0, count: columns)
        text.getCharacters(&window, range: NSRange(location: start, length: columns))

        var previous = Array(0...columns)
        var current = [Int](repeating: 0, count: columns + 1)
        for row in 1...rows {
            current[0] = row
            var rowBest = current[0]
            for column in 1...columns {
                let substitution = previous[column - 1] + (pattern[row - 1] == window[column - 1] ? 0 : 1)
                current[column] = min(substitution, min(previous[column] + 1, current[column - 1] + 1))
                rowBest = min(rowBest, current[column])
            }
            if rowBest > maxDistance { return nil }
            swap(&previous, &current)
        }
        var bestLength = 0
        var bestDistance = Int.max
        for column in 0...columns where previous[column] < bestDistance {
            bestDistance = previous[column]
            bestLength = column
        }
        guard bestDistance <= maxDistance else { return nil }
        return (bestLength, bestDistance)
    }

    // MARK: - Text helpers

    private static func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let start = min(max(0, range.location), length)
        let end = min(max(start, NSMaxRange(range)), length)
        return NSRange(location: start, length: end - start)
    }

    /// The quote, capped at `TextAnchor.exactLimit` and never cut through a
    /// character made of several units.
    private static func cappedText(of range: NSRange, in text: NSString) -> String {
        guard range.length > TextAnchor.exactLimit else { return text.substring(with: range) }
        var end = range.location + TextAnchor.exactLimit
        let composed = text.rangeOfComposedCharacterSequence(at: end - 1)
        if NSMaxRange(composed) > end { end = composed.location }
        return text.substring(with: NSRange(location: range.location, length: end - range.location))
    }
}

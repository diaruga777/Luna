import Foundation

/// Scores how well a short typed query matches a candidate string, for the
/// command palette's rows.
///
/// A candidate matches when every query token matches it. A token matches as
/// a whole word, a word prefix, a substring, or a subsequence whose letters
/// appear in order. Scores fall in `0...1`; nil means no match.
public enum FuzzyMatcher {

    /// The lowest score a subsequence match can earn, so a rank cut-off can
    /// drop the accidental ones.
    public static let subsequenceFloor = 0.2

    public static func score(query: String, candidate: String) -> Double? {
        let tokens = normalizedTokens(query)
        guard !tokens.isEmpty else { return nil }
        let target = normalize(candidate)
        guard !target.isEmpty else { return nil }
        if target == tokens.joined(separator: " ") { return 1 }
        // The weakest token determines the match: a common word must not
        // promote unrelated scattered letters in a longer symbol name.
        var weakest = 1.0
        for token in tokens {
            guard let part = score(token: token, in: target) else { return nil }
            weakest = min(weakest, part)
        }
        return weakest
    }

    /// Ranks `items` by the best score any of their search strings earns.
    /// Items scoring under `minimum` are dropped; ties keep list order.
    public static func rank<Item>(
        _ items: [Item], query: String, minimum: Double = subsequenceFloor,
        limit: Int = Int.max, searchStrings: (Item) -> [String]
    ) -> [(item: Item, score: Double)] {
        var scored: [(item: Item, score: Double, order: Int)] = []
        for (order, item) in items.enumerated() {
            var best: Double?
            for text in searchStrings(item) {
                guard let value = score(query: query, candidate: text) else { continue }
                if best == nil || value > best! { best = value }
            }
            if let best, best >= minimum { scored.append((item, best, order)) }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.order < rhs.order
        }
        return scored.prefix(max(0, limit)).map { ($0.item, $0.score) }
    }

    // MARK: - Token scoring

    private static func score(token: String, in target: String) -> Double? {
        let words = target.split(separator: " ").map(String.init)
        if words.contains(token) { return 0.95 }
        if target.hasPrefix(token) { return 0.9 }
        if words.contains(where: { $0.hasPrefix(token) }) { return 0.8 }
        if target.contains(token) { return 0.65 }
        return subsequenceScore(token: token, in: target)
    }

    /// Letters in order, rewarded for landing on word starts and for staying
    /// close together.
    private static func subsequenceScore(token: String, in target: String) -> Double? {
        let needle = Array(token)
        let hay = Array(target)
        guard needle.count >= 2, needle.count <= hay.count else { return nil }
        var index = 0
        var matched = 0
        var wordStarts = 0
        var gaps = 0
        var lastHit = -1
        while matched < needle.count, index < hay.count {
            if hay[index] == needle[matched] {
                if index == 0 || hay[index - 1] == " " { wordStarts += 1 }
                if lastHit >= 0 { gaps += index - lastHit - 1 }
                lastHit = index
                matched += 1
            }
            index += 1
        }
        guard matched == needle.count else { return nil }
        let density = Double(needle.count) / Double(needle.count + gaps)
        let starts = Double(wordStarts) / Double(needle.count)
        let value = subsequenceFloor + 0.25 * density + 0.15 * starts
        return min(value, 0.6)
    }

    // MARK: - Normalising

    static func normalizedTokens(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init)
    }

    /// Lower-cased, diacritics folded, punctuation turned to spaces, runs of
    /// spaces collapsed.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var out = ""
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingSpace = true
            }
        }
        return out
    }
}

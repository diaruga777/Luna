import Foundation
import NaturalLanguage

/// Finds words close in meaning to the
/// one typed.
public protocol WordThesaurus: AnyObject {
    /// True when a lookup can answer at all on this device.
    var isAvailable: Bool { get }
    /// Up to `limit` words, nearest first. Empty for a word it does not know.
    func matches(for word: String, limit: Int) -> [(word: String, score: Double)]
}

public extension WordThesaurus {
    func synonyms(for word: String, limit: Int) -> [String] {
        matches(for: word, limit: limit).map(\.word)
    }
}

/// A thesaurus over the system's on-device English word embedding, so the
/// lookup needs no network and no bundled dictionary.
///
/// Neighbours in embedding space are words used in the same places, which
/// puts synonyms first and near-synonyms and antonyms after them. Inflections
/// of the word itself ("happy" → "happier") are dropped: a writer asking for
/// another word does not want the same one bent.
public final class EmbeddingThesaurus: WordThesaurus {

    private let embedding: NLEmbedding?

    public init(language: NLLanguage = .english) {
        embedding = NLEmbedding.wordEmbedding(for: language)
    }

    public var isAvailable: Bool { embedding != nil }

    public func matches(for word: String, limit: Int) -> [(word: String, score: Double)] {
        guard let embedding, limit > 0 else { return [] }
        let needle = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty, !needle.contains(" ") else { return [] }
        let neighbours = embedding.neighbors(for: needle, maximumCount: limit * 3)
        var out: [(word: String, score: Double)] = []
        var seen: Set<String> = [needle]
        for (candidate, distance) in neighbours {
            let lower = candidate.lowercased()
            guard !seen.contains(lower), Self.isWordLike(lower), !Self.isInflection(lower, of: needle)
            else { continue }
            seen.insert(lower)
            // Cosine distance becomes similarity. Semantic alternatives sit
            // below direct word/prefix matches and never auto-replace prose.
            let score = min(0.79, max(0, 1 - distance))
            guard score > 0 else { continue }
            out.append((Self.matchCase(of: word, to: candidate), score))
            if out.count == limit { break }
        }
        return out
    }

    private static func isWordLike(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            CharacterSet.letters.contains($0) || $0 == "-" || $0 == "'"
        }
    }

    /// Same stem with only a common English ending changed: "happier",
    /// "happily" and "happiest" are all "happy" bent.
    static func isInflection(_ candidate: String, of word: String) -> Bool {
        let stem = { (text: String) -> String in
            var base = text
            for suffix in ["iest", "ier", "ily", "ing", "ies", "ied", "est", "ers", "ed", "er", "es", "ly", "s"]
            where text.hasSuffix(suffix) && text.count - suffix.count >= 3 {
                base = String(text.dropLast(suffix.count))
                break
            }
            // "happi" and "happy" are the same stem either side of a y→i change.
            if base.hasSuffix("y") || base.hasSuffix("i") { base = String(base.dropLast()) }
            return base
        }
        let a = stem(candidate)
        let b = stem(word)
        return a.count >= 3 && a == b
    }

    /// A capitalised query gets capitalised answers; an upper-cased one gets
    /// upper-cased answers.
    static func matchCase(of word: String, to candidate: String) -> String {
        if word == word.uppercased(), word.count > 1 { return candidate.uppercased() }
        if let first = word.first, first.isUppercase { return candidate.prefix(1).uppercased() + candidate.dropFirst() }
        return candidate
    }
}

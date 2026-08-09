//
//  ReadingHeuristics.swift
//  Luna
//

import Foundation

/// Lightweight, fully local linguistic heuristics for the phrase (chunk) speed
/// reader. These power "best-practice" chunking and per-chunk timing: grouping
/// words into meaningful phrases (keeping function words bound to the content
/// word they modify, starting new chunks at natural phrase boundaries) and
/// dwelling longer on cognitively heavier words (long / many-syllable / numeric)
/// while skimming common function words.
///
/// Everything here is pure and cheap (set lookups + a vowel-group scan), so it
/// runs inline while building the chunk list — no model, no network. Covered by
/// `ReadingHeuristicsTests`.
public enum ReadingHeuristics {

    /// Determiners/articles/possessives and the infinitive "to" — words that
    /// must stay attached to the word that FOLLOWS them. A chunk should never end
    /// on one of these (it strands the reader on "the" / "a" with no noun).
    static let leadingBinders: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those",
        "my", "your", "his", "her", "its", "our", "their",
        "to", "no", "every", "each", "some", "any", "another", "such",
    ]

    /// Prepositions, conjunctions and relative/subordinating words that naturally
    /// BEGIN a phrase. A new chunk prefers to start here (we break *before* them),
    /// which keeps prepositional/subordinate phrases intact as one fixation.
    static let phraseStarters: Set<String> = [
        // Prepositions
        "in", "on", "at", "of", "for", "with", "from", "by", "about",
        "into", "onto", "over", "under", "above", "below", "up", "down",
        "after", "before", "between", "through", "during", "without",
        "within", "against", "among", "across", "behind", "beyond",
        "toward", "towards", "upon", "off", "out", "near", "around", "per",
        // Conjunctions / subordinators / relatives
        "and", "but", "or", "nor", "so", "yet", "because", "although",
        "though", "while", "whereas", "since", "unless", "until", "if",
        "when", "where", "which", "who", "whom", "whose", "than", "as",
    ]

    /// All common function words (binders + starters + a few high-frequency
    /// extras). Used by the timing model to give very common words less dwell
    /// time — they are recognized almost instantly.
    static let functionWords: Set<String> = leadingBinders.union(phraseStarters).union([
        "is", "are", "was", "were", "be", "been", "being", "am",
        "do", "does", "did", "have", "has", "had", "will", "would",
        "can", "could", "shall", "should", "may", "might", "must",
        "i", "you", "he", "she", "it", "we", "they", "me", "him",
        "us", "them", "not", "all", "more", "most", "very", "just",
        "then", "there", "here", "what", "how", "why",
    ])

    /// The core word: lowercased with surrounding punctuation stripped, so
    /// "The," / "the" / "(the" all classify identically.
    public static func core(_ word: String) -> String {
        word.trimmingCharacters(in: punctuation).lowercased()
    }

    private static let punctuation = CharacterSet.punctuationCharacters
        .union(.symbols).union(.whitespacesAndNewlines)

    public static func isLeadingBinder(_ word: String) -> Bool { leadingBinders.contains(core(word)) }
    public static func isPhraseStarter(_ word: String) -> Bool { phraseStarters.contains(core(word)) }
    public static func isFunctionWord(_ word: String) -> Bool { functionWords.contains(core(word)) }

    /// Rough English syllable count from vowel groups (a fast, dependency-free
    /// proxy for word complexity). Not linguistically exact, but monotonic with
    /// difficulty, which is all the timing model needs.
    public static func syllableEstimate(_ word: String) -> Int {
        let lower = core(word)
        guard !lower.isEmpty else { return 0 }
        let vowels = Set("aeiouy")
        var count = 0
        var previousWasVowel = false
        for character in lower {
            let isVowel = vowels.contains(character)
            if isVowel && !previousWasVowel { count += 1 }
            previousWasVowel = isVowel
        }
        // A trailing silent "e" usually isn't its own syllable ("make", "time").
        if lower.count > 2, lower.hasSuffix("e"), !lower.hasSuffix("le") {
            count = max(1, count - 1)
        }
        return max(1, count)
    }

    /// Relative dwell time for a word, centered near 1.0 so a document's average
    /// stays close to the user's chosen WPM. Common function words read fast
    /// (recognized at a glance); long, many-syllable, or numeric words read
    /// slower (they need a real fixation).
    public static func difficultyFactor(_ word: String) -> Double {
        let lower = core(word)
        guard !lower.isEmpty else { return 0.6 }
        if functionWords.contains(lower) { return 0.6 }

        let length = lower.count
        let syllables = syllableEstimate(lower)
        var factor = 1.0
        if length >= 12 || syllables >= 5 {
            factor = 1.7
        } else if length >= 8 || syllables >= 4 {
            factor = 1.35
        } else if length <= 3 {
            // Short non-function words ("cat", "ran") are still quick.
            factor = 0.85
        }
        if word.contains(where: \.isNumber) { factor = max(factor, 1.4) }
        return factor
    }
}

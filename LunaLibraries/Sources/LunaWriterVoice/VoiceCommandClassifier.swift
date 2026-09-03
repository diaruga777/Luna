import Foundation

/// A Swift port of gazeread's `classify()` (`public/js/annotate.js`): turns a
/// spoken utterance into one of four editing commands or a free comment.
/// Same lexicon, normalisation, fuzzy tolerance and phrase-length rules —
/// `VoiceCommandClassifierTests` carries `test/classify.mjs`'s table.
public enum VoiceCommandClassifier {

    /// Loop order matters: gazeread checks red, blue, purple, green in that
    /// order, so a short utterance whose stop-word-free set matches more than
    /// one lexicon resolves the same way here.
    private enum Command: CaseIterable {
        case cut, expand, needsWork, keep

        var lexicon: [[String]] {
            switch self {
            case .needsWork:
                return ["needs work", "rephrase", "reword", "rewrite", "awkward", "clunky",
                        "unclear", "fix this", "tighten", "wordy", "confusing"].map(Self.words)
            case .expand:
                return ["expand", "elaborate", "more detail", "flesh out", "go deeper",
                        "say more", "more here", "unpack"].map(Self.words)
            case .cut:
                return ["remove", "cut", "delete", "drop this", "kill this", "scrap",
                        "cut this", "get rid of this"].map(Self.words)
            case .keep:
                return ["like this", "good", "great", "nice", "love it", "keep this",
                        "works well", "perfect", "love this", "yes"].map(Self.words)
            }
        }

        var voiceCommand: VoiceCommand {
            switch self {
            case .needsWork: return .needsWork
            case .expand: return .expand
            case .cut: return .cut
            case .keep: return .keep
            }
        }

        private static func words(_ phrase: String) -> [String] {
            phrase.split(separator: " ").map(String.init)
        }
    }

    private static let stopWords: Set<String> = [
        "a", "an", "the", "of", "bit", "this", "that", "it", "is", "to",
        "please", "um", "uh", "just", "really", "kind", "sort",
    ]

    /// Lower-cases, drops apostrophes, and turns every other run of
    /// non-alphanumeric characters into a token boundary.
    public static func normalize(_ text: String) -> [String] {
        var cleaned = text.lowercased()
        cleaned = cleaned.replacingOccurrences(of: "['\u{2019}]", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "[^a-z0-9\\s]", with: " ", options: .regularExpression)
        return cleaned.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Classic edit distance, used only for the small fuzzy tolerance below.
    public static func levenshtein(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        let aChars = Array(a), bChars = Array(b)
        let m = aChars.count, n = bChars.count
        if m == 0 { return n }
        if n == 0 { return m }
        var previous = Array(0...n)
        var current = [Int](repeating: 0, count: n + 1)
        for i in 1...m {
            current[0] = i
            for j in 1...n {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[n]
    }

    /// Two tokens match exactly, or within a tolerance that grows with the
    /// lexicon word's length — an ASR typo on a long word costs more edits
    /// than one on a short word.
    private static func tokensMatch(_ heard: String, _ want: String) -> Bool {
        if heard == want { return true }
        let tolerance = want.count >= 8 ? 2 : want.count >= 5 ? 1 : 0
        return tolerance > 0 && levenshtein(heard, want) <= tolerance
    }

    private static func containsPhrase(_ tokens: [String], _ phrase: [String]) -> Bool {
        guard phrase.count <= tokens.count else { return false }
        outer: for start in 0...(tokens.count - phrase.count) {
            for offset in 0..<phrase.count {
                if !tokensMatch(tokens[start + offset], phrase[offset]) { continue outer }
            }
            return true
        }
        return false
    }

    /// Classifies a transcript. `nil` means nothing usable was said (empty or
    /// punctuation-only); otherwise a command, or `.comment` holding the
    /// trimmed transcript.
    public static func classify(_ transcript: String) -> VoiceCommand? {
        let tokens = normalize(transcript)
        guard !tokens.isEmpty else { return nil }
        let content = tokens.filter { !stopWords.contains($0) }

        for command in Command.allCases {
            for phrase in command.lexicon {
                if phrase.count == 1 {
                    if tokens.count <= 4, containsPhrase(tokens, phrase) { return command.voiceCommand }
                    continue
                }
                if tokens.count <= 8, containsPhrase(tokens, phrase) { return command.voiceCommand }
                if tokens.count <= 6 {
                    let core = phrase.filter { !stopWords.contains($0) }
                    if !core.isEmpty, core.allSatisfy({ word in content.contains { tokensMatch($0, word) } }) {
                        return command.voiceCommand
                    }
                }
            }
        }
        return .comment(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

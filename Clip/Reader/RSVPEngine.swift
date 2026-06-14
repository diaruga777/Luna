//
//  RSVPEngine.swift
//  Clip
//

import Foundation

/// One word in the RSVP stream with everything needed to display and time it.
struct RSVPWord {
    let text: String
    /// Index of the highlighted ORP (optimal recognition point) letter.
    let orpIndex: Int
    /// True when the word ends a sentence (. ! ? …) — gets a longer pause.
    let endsSentence: Bool
    /// True for the last word of a block — gets the longest pause.
    let endsParagraph: Bool
    /// True when the word ends with a minor pause mark (, ; :).
    let endsClause: Bool
}

/// Turns extracted article blocks into a timed word stream for RSVP reading.
/// Pure logic, no UI — covered by unit tests.
struct RSVPEngine {
    let words: [RSVPWord]

    /// `maxCharactersPerWord` splits over-long words into multiple frames that
    /// fit the focal column (default `.max` = never split; used by tests).
    init(content: ArticleContent, maxCharactersPerWord: Int = .max) {
        var words: [RSVPWord] = []
        for block in content.blocks {
            let tokens = block.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            for (tokenIndex, token) in tokens.enumerated() {
                let isLastToken = tokenIndex == tokens.count - 1
                let parts = WordSplitter.split(token, maxCharacters: maxCharactersPerWord)
                for (partIndex, part) in parts.enumerated() {
                    let isLastPart = partIndex == parts.count - 1
                    // Only the final part carries the token's sentence/paragraph
                    // pause; continuation parts end in "-" and read straight on.
                    words.append(Self.makeWord(
                        part, isLastInBlock: isLastToken && isLastPart))
                }
            }
        }
        self.words = words
    }

    static func makeWord(_ token: String, isLastInBlock: Bool) -> RSVPWord {
        let trailing = token.last
        let endsSentence = trailing.map { ".!?…".contains($0) } ?? false
        let endsClause = trailing.map { ",;:".contains($0) } ?? false
        return RSVPWord(
            text: token,
            orpIndex: orpIndex(forLength: token.count),
            endsSentence: endsSentence,
            endsParagraph: isLastInBlock,
            endsClause: endsClause)
    }

    /// Spritz-style ORP: slightly left of center, drifting right for long words.
    static func orpIndex(forLength length: Int) -> Int {
        switch length {
        case ..<2: return 0
        case 2...5: return 1
        case 6...9: return 2
        default: return 3
        }
    }

    /// Display duration for the word at `index` at the given base speed.
    /// Longer words show longer; sentence and paragraph ends pause.
    func duration(at index: Int, wpm: Double) -> TimeInterval {
        guard words.indices.contains(index), wpm > 0 else { return 0 }
        let word = words[index]
        let base = 60.0 / wpm

        let lengthFactor: Double
        switch word.text.count {
        case ..<6: lengthFactor = 1.0
        case 6...9: lengthFactor = 1.3
        default: lengthFactor = 1.6
        }

        let pauseFactor: Double
        if word.endsParagraph {
            pauseFactor = 2.5
        } else if word.endsSentence {
            pauseFactor = 1.8
        } else if word.endsClause {
            pauseFactor = 1.3
        } else {
            pauseFactor = 1.0
        }

        return base * lengthFactor * pauseFactor
    }
}

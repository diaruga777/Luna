//
//  RSVPEngine.swift
//  Luna
//

import LunaModels
import Foundation

/// One word in the RSVP stream with everything needed to display and time it.
public struct RSVPWord {
    public let text: String
    /// Index of the highlighted ORP (optimal recognition point) letter.
    public let orpIndex: Int
    /// True when the word ends a sentence (. ! ? …) — gets a longer pause.
    public let endsSentence: Bool
    /// True for the last word of a block — gets the longest pause.
    public let endsParagraph: Bool
    /// True when the word ends with a minor pause mark (, ; :).
    public let endsClause: Bool
    /// The link this word belongs to, if it falls inside a block link range.
    public let url: URL?

    public init(
        text: String, orpIndex: Int, endsSentence: Bool, endsParagraph: Bool,
        endsClause: Bool, url: URL? = nil
    ) {
        self.text = text
        self.orpIndex = orpIndex
        self.endsSentence = endsSentence
        self.endsParagraph = endsParagraph
        self.endsClause = endsClause
        self.url = url
    }
}

/// Turns extracted article blocks into a timed word stream for RSVP reading.
/// Pure logic, no UI — covered by unit tests.
public struct RSVPEngine {
    public let words: [RSVPWord]
    /// Source-token index (the whitespace-token space WordMap and read-aloud
    /// share) for each entry of `words`. Splitting long tokens
    /// adds frames, so frame indices drift from the shared cross-mode space;
    /// these two maps convert both ways at the RSVP boundary.
    public let sourceTokenIndices: [Int]
    /// First frame index for each source token.
    public let firstFrameIndexByToken: [Int]

    /// `maxCharactersPerWord` splits over-long words into multiple frames that
    /// fit the focal column (default `.max` = never split; used by tests).
    public init(content: ArticleContent, maxCharactersPerWord: Int = .max) {
        var words: [RSVPWord] = []
        var sourceTokenIndices: [Int] = []
        var firstFrameIndexByToken: [Int] = []
        var tokenCounter = 0
        // A table of contents is rendered but never read. `WordMap` skips the same
        // blocks, so both sides of the shared word-index space stay aligned.
        for block in content.blocks where block.isReadableProse {
            let tokens = Self.tokensWithURLs(in: block)
            for (tokenIndex, token) in tokens.enumerated() {
                let isLastToken = tokenIndex == tokens.count - 1
                let parts = WordSplitter.split(token.text, maxCharacters: maxCharactersPerWord)
                firstFrameIndexByToken.append(words.count)
                for (partIndex, part) in parts.enumerated() {
                    let isLastPart = partIndex == parts.count - 1
                    // Only the final part carries the token's sentence/paragraph
                    // pause; continuation parts end in "-" and read straight on.
                    // Every part inherits the token's link.
                    words.append(Self.makeWord(
                        part, isLastInBlock: isLastToken && isLastPart, url: token.url))
                    sourceTokenIndices.append(tokenCounter)
                }
                tokenCounter += 1
            }
        }
        self.words = words
        self.sourceTokenIndices = sourceTokenIndices
        self.firstFrameIndexByToken = firstFrameIndexByToken
    }

    /// Frame to start on for a position expressed in the shared token space.
    public func frameIndex(forTokenIndex token: Int) -> Int? {
        guard firstFrameIndexByToken.indices.contains(token) else { return nil }
        return firstFrameIndexByToken[token]
    }

    /// The shared-token-space position of a frame.
    public func tokenIndex(forFrameIndex frame: Int) -> Int? {
        guard sourceTokenIndices.indices.contains(frame) else { return nil }
        return sourceTokenIndices[frame]
    }

    /// Whitespace-separated tokens with their link (if the token's UTF-16 range
    /// overlaps one of the block's link ranges).
    private static func tokensWithURLs(in block: ArticleContent.Block) -> [(text: String, url: URL?)] {
        func linkURL(start: Int, length: Int) -> URL? {
            for link in block.links
            where start < link.start + link.length && start + length > link.start {
                // An in-page jump is meaningless here: RSVP's link pill would offer
                // to open the article the reader is already inside.
                guard !link.isInPageAnchor else { return nil }
                return URL(string: link.urlString)
            }
            return nil
        }
        return WordTokenizer.tokens(in: block.text).map { token in
            (token.text, linkURL(start: token.utf16Start, length: token.utf16Length))
        }
    }

    private static func makeWord(_ token: String, isLastInBlock: Bool, url: URL? = nil) -> RSVPWord {
        let trailing = token.last
        let endsSentence = trailing.map { ".!?…".contains($0) } ?? false
        let endsClause = trailing.map { ",;:".contains($0) } ?? false
        return RSVPWord(
            text: token,
            orpIndex: orpIndex(forLength: token.count),
            endsSentence: endsSentence,
            endsParagraph: isLastInBlock,
            endsClause: endsClause,
            url: url)
    }

    /// Spritz-style ORP: slightly left of center, drifting right for long words.
    public static func orpIndex(forLength length: Int) -> Int {
        switch length {
        case ..<2: return 0
        case 2...5: return 1
        case 6...9: return 2
        default: return 3
        }
    }

    /// Index a skip button lands on: `currentIndex + delta`, clamped to a valid
    /// word index. An empty stream (`wordCount == 0`) clamps to 0. Pure so the
    /// skip math is unit-tested independent of the timer/TTS playback paths.
    public static func skipTarget(currentIndex: Int, by delta: Int, wordCount: Int) -> Int {
        let lastWord = max(wordCount - 1, 0)
        let target = currentIndex + delta
        return min(max(target, 0), lastWord)
    }

    /// Display duration for the word at `index` at the given base speed.
    /// Longer words show longer; sentence and paragraph ends pause.
    public func duration(at index: Int, wpm: Double) -> TimeInterval {
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

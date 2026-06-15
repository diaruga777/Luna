//
//  ChunkPlanner.swift
//  Clip
//

import Foundation

/// One highlighted group of words for the chunk-highlight reader.
struct TextChunk: Equatable {
    /// Half-open word-index range `[start, end)` in the shared word space.
    let wordRange: Range<Int>
    /// Character range in the rendered attributed string (union of the words).
    let characterRange: NSRange
    /// Pause weight of the last word (sentence/clause/paragraph end).
    let endsSentence: Bool
    let endsClause: Bool
    let endsParagraph: Bool
    /// Total characters across the chunk's words (for length-aware timing).
    let characterCount: Int
}

/// Groups an article's words into chunks for "chunk reading" (highlighting a
/// few words at a time) and times each chunk. Follows speed-reading practice:
/// 3–4 words per fixation, broken at punctuation/phrase boundaries, with the
/// per-word pace honoring the WPM setting plus pauses at sentence/clause ends.
/// Pure logic, unit-tested.
enum ChunkPlanner {

    static let maxWordsPerChunk = 4
    static let maxCharactersPerChunk = 24

    /// `words` and `wordRanges` share one index space (RSVPEngine / WordMap).
    static func chunks(words: [RSVPWord], wordRanges: [NSRange]) -> [TextChunk] {
        var chunks: [TextChunk] = []
        var start = 0
        let count = min(words.count, wordRanges.count)

        while start < count {
            var end = start
            var characters = 0
            while end < count {
                let wordLength = words[end].text.count
                let wouldBeWords = end - start + 1
                let wouldBeChars = characters + wordLength + (end > start ? 1 : 0)
                // Always take at least one word; otherwise stop before
                // exceeding the word or character budget.
                if end > start && (wouldBeWords > maxWordsPerChunk || wouldBeChars > maxCharactersPerChunk) {
                    break
                }
                characters = wouldBeChars
                // Close the chunk after a sentence/paragraph end, and after a
                // clause end once the chunk already holds a couple of words
                // (keeps short phrases together).
                let word = words[end]
                end += 1
                if word.endsSentence || word.endsParagraph { break }
                if word.endsClause && (end - start) >= 2 { break }
            }

            let last = words[end - 1]
            let first = wordRanges[start]
            let lastRange = wordRanges[end - 1]
            let characterRange = NSRange(
                location: first.location,
                length: lastRange.location + lastRange.length - first.location)
            chunks.append(TextChunk(
                wordRange: start..<end,
                characterRange: characterRange,
                endsSentence: last.endsSentence,
                endsClause: last.endsClause,
                endsParagraph: last.endsParagraph,
                characterCount: characters))
            start = end
        }
        return chunks
    }

    /// Display duration for a chunk at the given base words-per-minute. The
    /// per-word time matches the WPM; long chunks get a small length bump and
    /// punctuation boundaries pause longer (mirrors the RSVP timing curve).
    static func duration(for chunk: TextChunk, wpm: Double) -> TimeInterval {
        guard wpm > 0 else { return 0 }
        let wordCount = Double(chunk.wordRange.count)
        let base = wordCount * 60.0 / wpm

        // Slightly longer for dense chunks (more characters than ~5/word).
        let averageWordLength = Double(chunk.characterCount) / max(1, wordCount)
        let lengthFactor = averageWordLength > 7 ? 1.2 : 1.0

        let pauseFactor: Double
        if chunk.endsParagraph {
            pauseFactor = 2.0
        } else if chunk.endsSentence {
            pauseFactor = 1.6
        } else if chunk.endsClause {
            pauseFactor = 1.2
        } else {
            pauseFactor = 1.0
        }
        return base * lengthFactor * pauseFactor
    }
}

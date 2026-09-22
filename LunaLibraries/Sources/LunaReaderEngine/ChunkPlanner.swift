//
//  ChunkPlanner.swift
//  Luna
//

import Foundation

/// One phrase ("chunk") for the RSVP reader's phrase sub-mode: a small group of
/// words shown together so the eye takes them in as a single fixation.
public struct TextChunk: Equatable {
    /// Half-open word-index range `[start, end)` in the RSVPEngine word space.
    public let wordRange: Range<Int>
    /// The chunk's word texts, in order (what gets displayed, space-joined).
    public let words: [String]
    /// Pause weight of the last word.
    public let endsSentence: Bool
    public let endsClause: Bool
    public let endsParagraph: Bool

    public init(wordRange: Range<Int>, words: [String], endsSentence: Bool,
                endsClause: Bool, endsParagraph: Bool) {
        self.wordRange = wordRange
        self.words = words
        self.endsSentence = endsSentence
        self.endsClause = endsClause
        self.endsParagraph = endsParagraph
    }

    /// The space-joined display string for the phrase.
    public var displayText: String { words.joined(separator: " ") }
}

/// Groups an article's words into phrases for the RSVP "Phrases" sub-mode and
/// times each one. Follows speed-reading practice: a phrase is ~1–2 fixations
/// (a handful of words), broken at sentence/clause boundaries and at natural
/// phrase starts (prepositions/conjunctions), with function words kept bound to
/// the content word they modify (a chunk never ends on "the"/"a"/"in"). Timing
/// dwells longer on heavy words and at punctuation. Pure, unit-tested.
///
/// Works purely from the `RSVPEngine` word stream — no rendered attributed
/// string is needed, so the silent RSVP reader can drive it directly.
public enum ChunkPlanner {

    /// Soft ceilings so a phrase comfortably fits two short lines in the reticule.
    static let maxWordsPerChunk = 5
    static let maxCharactersPerChunk = 30
    /// A chunk may overrun the ceilings by this much to avoid stranding a bound
    /// word (e.g. pulling "house" in so the chunk doesn't end on "the").
    private static let overrunSlack = 6

    public static func chunks(words: [RSVPWord]) -> [TextChunk] {
        var chunks: [TextChunk] = []
        var start = 0
        let count = words.count
        while start < count {
            let end = chunkEnd(words: words, start: start)
            let slice = words[start..<end]
            let last = slice.last!
            chunks.append(TextChunk(
                wordRange: start..<end,
                words: slice.map(\.text),
                endsSentence: last.endsSentence,
                endsClause: last.endsClause,
                endsParagraph: last.endsParagraph))
            start = end
        }
        return chunks
    }

    /// Exclusive end index of the phrase that starts at `start`. Always returns
    /// at least `start + 1` (every word lands in exactly one chunk).
    private static func chunkEnd(words: [RSVPWord], start: Int) -> Int {
        let count = words.count
        let first = words[start]
        if first.endsSentence || first.endsParagraph { return start + 1 }

        var end = start + 1
        var characters = first.text.count

        while end < count {
            let word = words[end]
            let previous = words[end - 1]
            let prospectiveWords = end - start + 1
            let prospectiveChars = characters + 1 + word.text.count

            // Budget: stop before exceeding the word/char ceilings.
            if prospectiveWords > maxWordsPerChunk || prospectiveChars > maxCharactersPerChunk {
                break
            }
            // Hard boundary: the previous word closed a sentence/paragraph.
            if previous.endsSentence || previous.endsParagraph { break }

            let chunkHasBody = (end - start) >= 2
            let prevBinds = ReadingHeuristics.isLeadingBinder(previous.text)
            // Natural phrase start: break before a preposition/conjunction so
            // the phrase it introduces stays together as the next chunk.
            if chunkHasBody, !prevBinds, ReadingHeuristics.isPhraseStarter(word.text) { break }
            // Soft boundary: a clause mark (, ; :) once the chunk has some body.
            if chunkHasBody, !prevBinds, previous.endsClause { break }

            characters = prospectiveChars
            end += 1
            if word.endsSentence || word.endsParagraph { break }
        }

        // Never end a chunk on a binder ("in"/"the"/"to"): pull the next word in,
        // tolerating a small overrun so the bound word isn't stranded alone.
        while end < count,
              ReadingHeuristics.isLeadingBinder(words[end - 1].text),
              !words[end - 1].endsSentence, !words[end - 1].endsParagraph {
            let word = words[end]
            let prospectiveChars = characters + 1 + word.text.count
            if (end - start + 1) > maxWordsPerChunk + 1
                || prospectiveChars > maxCharactersPerChunk + overrunSlack { break }
            characters = prospectiveChars
            end += 1
            if word.endsSentence || word.endsParagraph { break }
        }

        return end
    }

    // MARK: - Timing

    /// Minimum on-screen time for a phrase regardless of WPM — two lines need a
    /// real (if quick) fixation, so high speeds don't flash them illegibly.
    static let minimumDisplay: TimeInterval = 0.28

    /// Display duration for a chunk at the given base words-per-minute. Per-word
    /// time honors the WPM but is weighted by each word's difficulty (common
    /// function words skim, long/complex/numeric words dwell), plus a pause at
    /// sentence/clause/paragraph boundaries.
    public static func duration(for chunk: TextChunk, wpm: Double) -> TimeInterval {
        guard wpm > 0 else { return 0 }
        let perWord = 60.0 / wpm
        let weight = chunk.words.reduce(0.0) { $0 + ReadingHeuristics.difficultyFactor($1) }

        let pauseWords: Double
        if chunk.endsParagraph {
            pauseWords = 1.6
        } else if chunk.endsSentence {
            pauseWords = 0.9
        } else if chunk.endsClause {
            pauseWords = 0.4
        } else {
            pauseWords = 0
        }

        let interval = perWord * (weight + pauseWords)
        return max(minimumDisplay, interval)
    }

    /// Total playback time from every chunk position through the end. Building
    /// the suffix totals once when content or WPM changes lets the Phrases UI
    /// update its time-remaining label with a single indexed lookup per advance.
    public static func remainingDurations(
        for chunks: [TextChunk], wpm: Double
    ) -> [TimeInterval] {
        guard wpm > 0 else { return Array(repeating: 0, count: chunks.count) }
        var result = Array(repeating: 0.0, count: chunks.count)
        var total = 0.0
        for index in chunks.indices.reversed() {
            total += duration(for: chunks[index], wpm: wpm)
            result[index] = total
        }
        return result
    }
}

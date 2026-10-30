import Foundation
import NaturalLanguage
import LunaStorage

/// Lossless slices of the same block text returned by Get Saved Item Text.
public enum ArticleTextChunks {
    public enum ChunkError: LocalizedError {
        case invalidMaximum, unavailable

        public var errorDescription: String? {
            switch self {
            case .invalidMaximum: return "Maximum Characters must be at least 1."
            case .unavailable: return "Choose a saved article or document with readable text."
            }
        }
    }

    public static func chunks(saveID: UUID, maximumCharacters: Int, store: SavesStore = .shared) throws -> [String] {
        guard let item = store.item(withID: saveID),
              ArticleReadability.isReadableArticle(item),
              let content = store.content(for: item) else {
            throw ChunkError.unavailable
        }
        return try split(content.blocks.map(\.text).joined(separator: "\n\n"),
                         maximumCharacters: maximumCharacters)
    }

    /// Counts Swift Characters (extended grapheme clusters), including separators.
    /// Prefer the last sentence ending within the limit. Only when none fits,
    /// fall back to a word boundary, then a character boundary for oversized words.
    /// Whitespace belongs to exactly one slice; joining with "" restores the input.
    public static func split(_ text: String, maximumCharacters: Int) throws -> [String] {
        guard maximumCharacters > 0 else { throw ChunkError.invalidMaximum }
        guard !text.isEmpty else { return [] }

        let sentences = NLTokenizer(unit: .sentence)
        sentences.string = text
        var sentenceEnds = sentences.tokens(for: text.startIndex..<text.endIndex).map { range in
            var end = range.upperBound
            // Leave separators for the next slice so a sentence exactly at the
            // character limit still fits. Never trim or discard them from output.
            while end > range.lowerBound, text[text.index(before: end)].isWhitespace {
                end = text.index(before: end)
            }
            return end
        }
        sentenceEnds.append(text.endIndex)

        let words = NLTokenizer(unit: .word)
        words.string = text
        // Both sides of words are lossless cutoffs, including for languages
        // without spaces. Next-word starts also retain punctuation/separators.
        let wordEnds = Array(Set(words.tokens(for: text.startIndex..<text.endIndex)
            .flatMap { [$0.lowerBound, $0.upperBound] })).sorted()
        var sentenceCursor = 0
        var wordCursor = 0
        var start = text.startIndex
        var chunks: [String] = []
        while start < text.endIndex {
            let limit = text.index(start, offsetBy: maximumCharacters, limitedBy: text.endIndex) ?? text.endIndex
            let sentenceEnd = lastBoundary(sentenceEnds, cursor: &sentenceCursor, after: start, through: limit)
            var end = sentenceEnd
            if end == nil {
                end = lastBoundary(wordEnds, cursor: &wordCursor, after: start, through: limit)
                // A word can end exactly at the limit even when its following
                // separator does not fit. Prefer that cutoff to an earlier word.
                if limit < text.endIndex, text[limit].isWhitespace {
                    end = limit
                }
            }
            let cutoff = end ?? limit
            chunks.append(String(text[start..<cutoff]))
            start = cutoff
        }
        return chunks
    }

    private static func lastBoundary(_ boundaries: [String.Index], cursor: inout Int,
                                     after start: String.Index, through limit: String.Index) -> String.Index? {
        var result: String.Index?
        while cursor < boundaries.count, boundaries[cursor] <= limit {
            if boundaries[cursor] > start { result = boundaries[cursor] }
            cursor += 1
        }
        return result
    }
}

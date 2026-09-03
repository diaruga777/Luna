import Foundation

/// Counts what the writer watches: words, characters, sentences, paragraphs
/// and the time the piece takes to read. One pass, no tokenizer, so the whole
/// document can be measured on every debounce.
public enum TextStatistics {

    public struct Stats: Equatable, Sendable {
        public var words: Int
        /// Characters the reader sees, spaces included.
        public var characters: Int
        public var charactersWithoutSpaces: Int
        public var sentences: Int
        public var paragraphs: Int
        public var readingTime: TimeInterval

        public init(
            words: Int = 0,
            characters: Int = 0,
            charactersWithoutSpaces: Int = 0,
            sentences: Int = 0,
            paragraphs: Int = 0,
            readingTime: TimeInterval = 0
        ) {
            self.words = words
            self.characters = characters
            self.charactersWithoutSpaces = charactersWithoutSpaces
            self.sentences = sentences
            self.paragraphs = paragraphs
            self.readingTime = readingTime
        }
    }

    /// Adult silent reading speed for prose.
    public static let defaultWordsPerMinute: Double = 238

    public static func measure(_ text: String, range: NSRange? = nil, wordsPerMinute: Double = defaultWordsPerMinute) -> Stats {
        measure(text as NSString, range: range, wordsPerMinute: wordsPerMinute)
    }

    public static func measure(_ text: NSString, range: NSRange? = nil, wordsPerMinute: Double = defaultWordsPerMinute) -> Stats {
        let scope = range ?? NSRange(location: 0, length: text.length)
        guard scope.length > 0, NSMaxRange(scope) <= text.length else { return Stats() }
        return count(text.substring(with: scope), wordsPerMinute: wordsPerMinute)
    }

    private static let joiners: Set<Character> = ["'", "\u{2019}", "-", "\u{2011}", "_", ","]
    private static let terminators: Set<Character> = [".", "!", "?", "\u{2026}", "。", "！", "？"]
    private static let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]", "}", "»"]

    private static func count(_ body: String, wordsPerMinute: Double) -> Stats {
        var stats = Stats()
        var inWord = false
        var lineHasContent = false
        var inParagraph = false
        var sentenceHasWord = false
        var pendingTerminator: Character?
        var currentToken = ""

        func closeSentence() {
            guard let terminator = pendingTerminator else { return }
            pendingTerminator = nil
            guard sentenceHasWord else { return }
            if terminator == ".", SentenceSegmenter.endsWithAbbreviation(currentToken) { return }
            stats.sentences += 1
            sentenceHasWord = false
            currentToken = ""
        }

        for character in body {
            stats.characters += 1
            let isWordCharacter = character.isLetter || character.isNumber
            let isNewline = character.isNewline
            let isWhitespace = character.isWhitespace

            if !isWhitespace { stats.charactersWithoutSpaces += 1 }

            if isWordCharacter {
                if !inWord { stats.words += 1; inWord = true }
                sentenceHasWord = true
                // A stop with a word right after it is a decimal point or an
                // ellipsis inside a word, never the end of a sentence.
                pendingTerminator = nil
                currentToken.append(character)
            } else if terminators.contains(character) {
                // The stop may still be inside a word, as in "$1.50" or
                // "e.g."; whatever comes next decides.
                currentToken.append(character)
                pendingTerminator = character
            } else if joiners.contains(character), inWord {
                currentToken.append(character)
            } else if closers.contains(character) {
                inWord = false
                currentToken.append(character)
            } else if isWhitespace {
                inWord = false
                closeSentence()
                currentToken = ""
            } else {
                inWord = false
                pendingTerminator = nil
                currentToken = ""
            }

            if isNewline {
                if lineHasContent, !inParagraph { stats.paragraphs += 1; inParagraph = true }
                if !lineHasContent { inParagraph = false }
                lineHasContent = false
            } else if !isWhitespace {
                lineHasContent = true
            }
        }

        closeSentence()
        if sentenceHasWord { stats.sentences += 1 }
        if lineHasContent, !inParagraph { stats.paragraphs += 1 }
        stats.readingTime = wordsPerMinute > 0 ? Double(stats.words) / wordsPerMinute * 60 : 0
        return stats
    }
}

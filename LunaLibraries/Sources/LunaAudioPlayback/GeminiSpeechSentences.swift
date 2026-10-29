import Foundation
import NaturalLanguage

enum GeminiSpeechSentences {
    /// Include separators in the preceding sentence so concatenating ranges is
    /// lossless. Tokenize each paragraph separately to keep headings intact.
    static func ranges(in text: String) -> [NSRange] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        let starts = tokenizer.tokens(for: text.startIndex..<text.endIndex).map { $0.lowerBound.utf16Offset(in: text) }
        guard !starts.isEmpty else { return text.isEmpty ? [] : [NSRange(location: 0, length: text.utf16.count)] }
        let ends = Array(starts.dropFirst()) + [text.utf16.count]
        var start = 0
        return ends.map { end in
            defer { start = end }
            return NSRange(location: start, length: end - start)
        }
    }

    static func chunks(in text: String, sentences: [NSRange], maxBytes: Int = 7_500, maxWords: Int = 1_200) -> [NSRange] {
        let source = text as NSString
        var chunks: [NSRange] = []
        var start = 0, end = 0, bytes = 0, words = 0
        for sentence in sentences {
            let body = source.substring(with: sentence)
            let size = body.utf8.count, count = AudioWordIndexing.wordCount(in: body)
            if end > start, bytes + size > maxBytes || words + count > maxWords {
                chunks.append(NSRange(location: start, length: end - start))
                start = end; bytes = 0; words = 0
            }
            // A single oversized sentence is indivisible. These are targets,
            // not permission to cut a word or sentence in half.
            end = NSMaxRange(sentence); bytes += size; words += count
        }
        if end > start { chunks.append(NSRange(location: start, length: end - start)) }
        return chunks
    }
}

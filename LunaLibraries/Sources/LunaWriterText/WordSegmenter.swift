import Foundation
import NaturalLanguage

/// Splits a range into words. Punctuation and whitespace get no token, so the
/// statistics, the tagger and the reading tracker all count the same things.
public final class WordSegmenter {
    private let tokenizer = NLTokenizer(unit: .word)

    public init() {}

    public func words(in range: NSRange, of text: NSString) -> [NSRange] {
        guard range.length > 0, NSMaxRange(range) <= text.length else { return [] }
        let body = text.substring(with: range)
        tokenizer.string = body
        var out: [NSRange] = []
        tokenizer.enumerateTokens(in: body.startIndex..<body.endIndex) { tokenRange, _ in
            let nsRange = NSRange(tokenRange, in: body)
            if nsRange.length > 0 {
                out.append(NSRange(location: nsRange.location + range.location, length: nsRange.length))
            }
            return true
        }
        return out
    }

    /// The word that holds `offset`, or nil when the offset sits on
    /// punctuation or whitespace.
    public func wordRange(containing offset: Int, in range: NSRange, of text: NSString) -> NSRange? {
        words(in: range, of: text).first { offset >= $0.location && offset < NSMaxRange($0) }
    }
}

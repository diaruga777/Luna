//
//  WordMap.swift
//  Luna
//

import LunaModels
import Foundation

/// Maps between the article's word stream (the same indices RSVPEngine uses)
/// and character ranges in the rendered attributed string. Lets read-aloud,
/// eye tracking, RSVP, and the scroll reader share one "word index" space.
public struct WordMap {
    /// Attributed-string range for each word, indexed by word index.
    public let wordRanges: [NSRange]

    public init(content: ArticleContent, rendered: RenderedArticle) {
        var ranges: [NSRange] = []
        for (blockIndex, block) in content.blocks.enumerated() {
            let blockText = block.text as NSString
            guard let blockRange = rendered.blockTextRanges[safe: blockIndex] ?? nil else {
                // Image/skipped blocks contribute no words (matches RSVPEngine,
                // whose tokenizer yields nothing for empty text).
                continue
            }
            // Tokenize exactly like RSVPEngine: split on whitespace.
            var searchLocation = 0
            let tokens = block.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            for token in tokens {
                let tokenRange = blockText.range(
                    of: token,
                    range: NSRange(location: searchLocation, length: blockText.length - searchLocation))
                guard tokenRange.location != NSNotFound else { continue }
                searchLocation = tokenRange.location + tokenRange.length
                ranges.append(NSRange(
                    location: blockRange.location + tokenRange.location,
                    length: tokenRange.length))
            }
        }
        self.wordRanges = ranges
    }

    public var wordCount: Int { wordRanges.count }

    public func attributedRange(forWord index: Int) -> NSRange? {
        wordRanges[safe: index]
    }

    /// The word whose range contains (or is nearest after) the character index.
    public func wordIndex(nearCharacterIndex characterIndex: Int) -> Int? {
        guard !wordRanges.isEmpty else { return nil }
        var low = 0
        var high = wordRanges.count - 1
        while low < high {
            let mid = (low + high) / 2
            if wordRanges[mid].location + wordRanges[mid].length <= characterIndex {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}

public extension Array {
    public subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

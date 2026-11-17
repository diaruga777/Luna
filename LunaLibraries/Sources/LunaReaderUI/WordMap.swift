//
//  WordMap.swift
//  Luna
//

import LunaModels
import LunaReaderEngine
import Foundation

/// Maps between the article's word stream (the same indices RSVPEngine uses)
/// and character ranges in the rendered attributed string. Lets read-aloud,
/// RSVP, and the scroll reader share one "word index" space.
public struct WordMap {
    /// Attributed-string range for each word, indexed by word index.
    public let wordRanges: [NSRange]

    public init(content: ArticleContent, rendered: RenderedArticle) {
        var ranges: [NSRange] = []
        // A preview only has ranges for its rendered prefix. The tokenizer
        // already supplies the exact UTF-16 offsets, including repeated words.
        for (block, range) in zip(content.blocks, rendered.blockTextRanges) {
            guard block.isReadableProse, let range else { continue }
            for token in WordTokenizer.tokens(in: block.text) {
                ranges.append(NSRange(location: range.location + token.utf16Start,
                                      length: token.utf16Length))
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
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

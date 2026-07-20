//
//  WordTokenizer.swift
//  LunaReaderEngine
//

import Foundation

/// The one whitespace-splitting definition of "word index" shared across the
/// module: `RSVPEngine`'s own tokenizer (which also needs each token's UTF-16
/// position, to test it against link ranges) and `WordMap`'s (which only
/// needs the token strings, byte-identical to `RSVPEngine`'s so the two stay
/// in the same index space). Splitting any other way here would desync them.
public enum WordTokenizer {
    /// A whitespace-delimited token plus its UTF-16 start offset/length
    /// within the source text.
    public struct Token {
        public let text: String
        public let utf16Start: Int
        public let utf16Length: Int
    }

    /// Splits `text` into maximal runs of non-whitespace characters, in
    /// order, dropping empty runs — the same shape as
    /// `text.split(whereSeparator: { $0.isWhitespace })` but walked once,
    /// UTF-16-offset-tracking, character by character.
    public static func tokens(in text: String) -> [Token] {
        var result: [Token] = []
        var current = ""
        var currentStart = 0
        var utf16Offset = 0

        func flush() {
            guard !current.isEmpty else { return }
            result.append(Token(text: current, utf16Start: currentStart, utf16Length: utf16Offset - currentStart))
            current = ""
        }

        for character in text {
            let characterLength = String(character).utf16.count
            if character.isWhitespace {
                flush()
            } else {
                if current.isEmpty { currentStart = utf16Offset }
                current.append(character)
            }
            utf16Offset += characterLength
        }
        flush()
        return result
    }
}

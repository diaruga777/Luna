//
//  CLIPTextTokenizer.swift
//  clipper
//

import Foundation

/// Tokenizes free text into the fixed-length integer token IDs the CLIP text
/// encoder expects.
protocol CLIPTextTokenizer: Sendable {
    /// Returns exactly `contextLength` token IDs: a start-of-text sentinel, the
    /// byte-pair-encoded tokens, an end-of-text sentinel, then zero padding. If
    /// the text is too long it is truncated and the final slot is forced back to
    /// the end-of-text sentinel.
    func encode(_ text: String, contextLength: Int) -> [Int32]
}

/// A faithful port of OpenAI CLIP's byte-level BPE tokenizer (`SimpleTokenizer`),
/// which MobileCLIP's text tower reuses. Construction is from the merge-rule list
/// shipped in `clip_merges.txt`; the vocabulary is derived deterministically from
/// the byte→unicode table plus those merges.
final class BPECLIPTokenizer: CLIPTextTokenizer {

    private let byteEncoder: [UInt8: String]
    private let encoder: [String: Int32]
    private let bpeRanks: [Pair: Int]
    private let startOfText: Int32
    private let endOfText: Int32

    /// The CLIP pre-tokenization pattern. The literal is a known-valid ICU regex,
    /// so compilation cannot fail at runtime.
    private static let tokenPattern: NSRegularExpression = {
        let pattern = "<\\|startoftext\\|>|<\\|endoftext\\|>|'s|'t|'re|'ve|'m|'ll|'d|[\\p{L}]+|[\\p{N}]|[^\\s\\p{L}\\p{N}]+"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// An ordered pair of BPE symbols.
    private struct Pair: Hashable {
        let first: String
        let second: String
    }

    /// Builds the tokenizer from the raw merges-file contents (one "a b" merge
    /// rule per line, highest priority first).
    init(mergesFileContents: String) {
        // Ordered so the vocabulary indices match CLIP's: base characters follow
        // the byte→unicode *insertion* order, not sorted byte value.
        let ordered = Self.bytesToUnicodeOrdered()
        self.byteEncoder = Dictionary(uniqueKeysWithValues: ordered)

        let merges: [Pair] = mergesFileContents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                let parts = line.split(separator: " ")
                guard parts.count == 2 else { return nil }
                return Pair(first: String(parts[0]), second: String(parts[1]))
            }

        // Vocabulary: 256 base byte-chars, the same 256 with a word-end marker,
        // then every merged symbol, then the two special tokens.
        let baseChars = ordered.map { $0.1 }
        var vocab = baseChars
        vocab.append(contentsOf: baseChars.map { $0 + "</w>" })
        vocab.append(contentsOf: merges.map { $0.first + $0.second })
        vocab.append("<|startoftext|>")
        vocab.append("<|endoftext|>")

        var encoder: [String: Int32] = [:]
        encoder.reserveCapacity(vocab.count)
        for (index, token) in vocab.enumerated() {
            encoder[token] = Int32(index)
        }
        self.encoder = encoder
        self.startOfText = encoder["<|startoftext|>"] ?? 49406
        self.endOfText = encoder["<|endoftext|>"] ?? 49407

        var ranks: [Pair: Int] = [:]
        ranks.reserveCapacity(merges.count)
        for (index, pair) in merges.enumerated() {
            ranks[pair] = index
        }
        self.bpeRanks = ranks
    }

    func encode(_ text: String, contextLength: Int) -> [Int32] {
        var ids: [Int32] = [startOfText]
        for word in regexTokens(in: Self.clean(text)) {
            // Map each UTF-8 byte of the word to its unicode placeholder, then
            // run BPE over that placeholder string.
            let bytes = Array(word.utf8)
            let placeholder = bytes.map { byteEncoder[$0] ?? "" }.joined()
            guard !placeholder.isEmpty else { continue }
            for token in bpe(placeholder) {
                if let id = encoder[token] {
                    ids.append(id)
                }
            }
        }
        ids.append(endOfText)

        if ids.count > contextLength {
            ids = Array(ids.prefix(contextLength))
            ids[contextLength - 1] = endOfText
        } else if ids.count < contextLength {
            ids.append(contentsOf: Array(repeating: 0, count: contextLength - ids.count))
        }
        return ids
    }

    // MARK: - BPE

    /// Applies byte-pair merges to a single pre-token, returning its sub-word
    /// pieces. Operates on the byte→unicode placeholder representation.
    private func bpe(_ token: String) -> [String] {
        var word = token.map { String($0) }
        guard !word.isEmpty else { return [] }
        // Mark the final symbol with the end-of-word suffix.
        word[word.count - 1] = word[word.count - 1] + "</w>"

        while word.count > 1 {
            // Find the adjacent pair with the best (lowest) merge rank.
            var bestRank = Int.max
            var bestIndex: Int?
            for index in 0..<(word.count - 1) {
                let pair = Pair(first: word[index], second: word[index + 1])
                if let rank = bpeRanks[pair], rank < bestRank {
                    bestRank = rank
                    bestIndex = index
                }
            }
            guard let mergeIndex = bestIndex else { break }

            // Merge every non-overlapping occurrence of the chosen pair.
            let first = word[mergeIndex]
            let second = word[mergeIndex + 1]
            var merged: [String] = []
            var i = 0
            while i < word.count {
                if i < word.count - 1, word[i] == first, word[i + 1] == second {
                    merged.append(first + second)
                    i += 2
                } else {
                    merged.append(word[i])
                    i += 1
                }
            }
            word = merged
        }
        return word
    }

    // MARK: - Pre-tokenization

    private func regexTokens(in text: String) -> [String] {
        let ns = text as NSString
        let matches = Self.tokenPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return matches.map { ns.substring(with: $0.range) }
    }

    /// Lowercases and collapses whitespace, matching CLIP's basic cleaning.
    private static func clean(_ text: String) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.lowercased()
    }

    // MARK: - Byte ↔ unicode table

    /// The reversible byte→unicode mapping CLIP uses so that BPE can operate on
    /// printable characters without ever hitting whitespace control bytes.
    /// Returned in insertion order (printable ranges first, then the remapped
    /// control bytes) — this order defines the base-vocabulary indices.
    private static func bytesToUnicodeOrdered() -> [(UInt8, String)] {
        var byteList: [Int] = []
        byteList.append(contentsOf: 0x21...0x7E)   // '!'...'~'
        byteList.append(contentsOf: 0xA1...0xAC)
        byteList.append(contentsOf: 0xAE...0xFF)

        var codes = byteList
        var n = 0
        for b in 0...255 where !byteList.contains(b) {
            byteList.append(b)
            codes.append(256 + n)
            n += 1
        }

        return zip(byteList, codes).map { (UInt8($0), String(UnicodeScalar($1)!)) }
    }
}

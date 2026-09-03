import Foundation
import NaturalLanguage

/// Splits a paragraph into sentences. `NLTokenizer` does the work; the
/// abbreviation guard puts back the sentences it breaks at "Mr." or at an
/// initial, which read-along would otherwise treat as two bands.
public final class SentenceSegmenter {
    /// A paragraph identified by position and the document revision it was
    /// read at, so a hit needs no text at all — only the caller's own
    /// bookkeeping, which it already keeps for its own change tracking.
    private struct RevisionKey: Hashable {
        var location: Int
        var length: Int
        var revision: Int
    }

    private var textCache: LRUCache<String, [NSRange]>
    private var revisionCache: LRUCache<RevisionKey, [NSRange]>

    public init(cacheLimit: Int = 128) {
        textCache = LRUCache(limit: cacheLimit)
        revisionCache = LRUCache(limit: cacheLimit)
    }

    /// Sentence ranges inside `paragraph`, in document offsets and in order.
    ///
    /// `revision` identifies the text's current edit count. Passing it lets
    /// a cache hit skip bridging `text` to a `String` entirely; omitting it
    /// falls back to keying on the paragraph's own text, unchanged.
    public func sentences(in paragraph: NSRange, of text: NSString, revision: Int? = nil) -> [NSRange] {
        guard paragraph.length > 0, NSMaxRange(paragraph) <= text.length else { return [] }
        let relative: [NSRange]
        if let revision {
            let key = RevisionKey(location: paragraph.location, length: paragraph.length, revision: revision)
            if let cached = revisionCache.value(for: key) {
                relative = cached
            } else {
                relative = SentenceSegmenter.segment(text.substring(with: paragraph))
                revisionCache.insert(relative, for: key)
            }
        } else {
            let body = text.substring(with: paragraph)
            if let cached = textCache.value(for: body) {
                relative = cached
            } else {
                relative = SentenceSegmenter.segment(body)
                textCache.insert(relative, for: body)
            }
        }
        guard paragraph.location != 0 else { return relative }
        return relative.map { NSRange(location: $0.location + paragraph.location, length: $0.length) }
    }

    /// The sentence that holds `offset`. An offset in the whitespace between
    /// two sentences belongs to the sentence before it.
    public func sentenceRange(containing offset: Int, in paragraph: NSRange, of text: NSString, revision: Int? = nil) -> NSRange? {
        let all = sentences(in: paragraph, of: text, revision: revision)
        guard !all.isEmpty else { return nil }
        var best: NSRange?
        for sentence in all {
            if offset < sentence.location { break }
            best = sentence
            if offset < NSMaxRange(sentence) { return sentence }
        }
        return best
    }

    public func clearCache() {
        textCache.removeAll()
        revisionCache.removeAll()
    }

    // MARK: - Segmentation

    /// Counts calls into the real tokenizer, so a test can show a cache hit
    /// skipped it rather than only checking the answer matches.
    static var tokenizeCallCountForTesting = 0

    private static func segment(_ body: String) -> [NSRange] {
        tokenizeCallCountForTesting += 1
        var pieces: [NSRange] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = body
        tokenizer.enumerateTokens(in: body.startIndex..<body.endIndex) { range, _ in
            let nsRange = NSRange(range, in: body)
            if nsRange.length > 0 { pieces.append(nsRange) }
            return true
        }
        guard !pieces.isEmpty else { return [] }

        let text = body as NSString
        var merged: [NSRange] = []
        var index = 0
        while index < pieces.count {
            var current = pieces[index]
            // Whether the sentence-so-far ends in an abbreviation depends
            // only on its last piece, so only that piece is re-read here —
            // never the whole, ever-growing merged run.
            var tail = text.substring(with: current)
            while index + 1 < pieces.count, endsWithAbbreviation(tail) {
                let next = pieces[index + 1]
                current = NSRange(location: current.location, length: NSMaxRange(next) - current.location)
                tail = text.substring(with: next)
                index += 1
            }
            merged.append(current)
            index += 1
        }
        return merged
    }

    /// True when a full stop closes a known short form or an initial, so the
    /// sentence has not really ended.
    static func endsWithAbbreviation(_ sentence: String) -> Bool {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(".") else { return false }
        guard let last = trimmed.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).last else { return false }
        let token = last.trimmingCharacters(in: CharacterSet(charactersIn: "([\"'“‘"))
        if abbreviations.contains(token.lowercased()) { return true }
        // An initial: one letter and a stop, as in "J. R. R. Tolkien".
        let letters = token.dropLast()
        return letters.count == 1 && letters.allSatisfy { $0.isLetter && $0.isUppercase }
    }

    static let abbreviations: Set<String> = [
        "mr.", "mrs.", "ms.", "dr.", "prof.", "sr.", "jr.", "st.", "rev.", "hon.", "gen.", "col.",
        "sgt.", "lt.", "capt.", "gov.", "sen.", "rep.", "vs.", "etc.", "e.g.", "i.e.", "cf.", "al.",
        "fig.", "figs.", "no.", "nos.", "vol.", "pp.", "ch.", "sec.", "dept.", "est.", "approx.",
        "inc.", "ltd.", "co.", "corp.", "univ.", "ave.", "rd.", "blvd.", "mt.", "ft.", "min.", "max.",
        "jan.", "feb.", "mar.", "apr.", "jun.", "jul.", "aug.", "sept.", "sep.", "oct.", "nov.", "dec.",
    ]
}

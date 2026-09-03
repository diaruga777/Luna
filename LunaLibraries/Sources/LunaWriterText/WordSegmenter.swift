import Foundation
import NaturalLanguage

/// Splits a range into words. Punctuation and whitespace get no token, so the
/// statistics, the tagger and the reading tracker all count the same things.
public final class WordSegmenter {
    private struct RevisionKey: Hashable {
        var location: Int
        var length: Int
        var revision: Int
    }

    private let tokenizer = NLTokenizer(unit: .word)
    private var textCache: LRUCache<String, [NSRange]>
    private var revisionCache: LRUCache<RevisionKey, [NSRange]>

    public init(cacheLimit: Int = 128) {
        textCache = LRUCache(limit: cacheLimit)
        revisionCache = LRUCache(limit: cacheLimit)
    }

    /// Word ranges inside `range`, in document offsets and in order.
    ///
    /// `revision` identifies the text's current edit count. Passing it lets
    /// a cache hit skip bridging `text` to a `String` entirely; omitting it
    /// falls back to keying on the range's own text, unchanged.
    public func words(in range: NSRange, of text: NSString, revision: Int? = nil) -> [NSRange] {
        guard range.length > 0, NSMaxRange(range) <= text.length else { return [] }
        let relative: [NSRange]
        if let revision {
            let key = RevisionKey(location: range.location, length: range.length, revision: revision)
            if let cached = revisionCache.value(for: key) {
                relative = cached
            } else {
                relative = tokenize(text.substring(with: range))
                revisionCache.insert(relative, for: key)
            }
        } else {
            let body = text.substring(with: range)
            if let cached = textCache.value(for: body) {
                relative = cached
            } else {
                relative = tokenize(body)
                textCache.insert(relative, for: body)
            }
        }
        guard range.location != 0 else { return relative }
        return relative.map { NSRange(location: $0.location + range.location, length: $0.length) }
    }

    /// The word that holds `offset`, or nil when the offset sits on
    /// punctuation or whitespace.
    public func wordRange(containing offset: Int, in range: NSRange, of text: NSString, revision: Int? = nil) -> NSRange? {
        words(in: range, of: text, revision: revision).first { offset >= $0.location && offset < NSMaxRange($0) }
    }

    public func clearCache() {
        textCache.removeAll()
        revisionCache.removeAll()
    }

    private func tokenize(_ body: String) -> [NSRange] {
        tokenizer.string = body
        var out: [NSRange] = []
        tokenizer.enumerateTokens(in: body.startIndex..<body.endIndex) { tokenRange, _ in
            let nsRange = NSRange(tokenRange, in: body)
            if nsRange.length > 0 { out.append(nsRange) }
            return true
        }
        return out
    }
}

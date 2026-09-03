//
//  SentenceGeometryProvider.swift
//  LunaWriterEditor
//

import UIKit
import LunaGaze
import LunaWriterText

/// Where each sentence and each of its words sit on the page.
///
/// Rectangles are in text-container coordinates, so they do not move when the
/// view scrolls — the same document coordinates gazeread works in. The answer
/// is cached until the storage rescans the text under it.
public final class SentenceGeometryProvider: MarkdownTextStorageObserving {

    private weak var layoutManager: NSTextLayoutManager?
    private let storage: MarkdownTextStorage
    private let sentences: SentenceSegmenter
    private let words: WordSegmenter

    public weak var viewportProvider: RenderingViewportProviding?

    private var sentenceRanges: [NSRange]?
    private var cache: [Int: SentenceLayout] = [:]

    public init(
        layoutManager: NSTextLayoutManager?,
        storage: MarkdownTextStorage,
        sentences: SentenceSegmenter = SentenceSegmenter(),
        words: WordSegmenter = WordSegmenter()
    ) {
        self.layoutManager = layoutManager
        self.storage = storage
        self.sentences = sentences
        self.words = words
        storage.addObserver(self)
    }

    // MARK: - Public

    /// Every sentence that touches `range`, in document order.
    public func layout(for range: NSRange) -> [SentenceLayout] {
        let ranges = allSentenceRanges()
        var out: [SentenceLayout] = []
        for (index, sentence) in ranges.enumerated() {
            guard NSIntersectionRange(sentence, range).length > 0 || sentence.location == range.location else { continue }
            if let layout = sentenceLayout(index: index, range: sentence) { out.append(layout) }
        }
        return out
    }

    /// The sentences the viewport shows.
    public func visibleSentences() -> [SentenceLayout] {
        let range = viewportProvider?.renderingViewportRange
            ?? NSRange(location: 0, length: storage.length)
        return layout(for: range)
    }

    /// The sentence whose lines sit closest to a height on the page.
    public func nearestSentence(toY y: CGFloat) -> SentenceLayout? {
        let all = layout(for: NSRange(location: 0, length: storage.length))
        var best: SentenceLayout?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for sentence in all {
            for rect in sentence.lineRects {
                let distance = rect.minY > y ? rect.minY - y : (rect.maxY < y ? y - rect.maxY : 0)
                if distance < bestDistance {
                    bestDistance = distance
                    best = sentence
                }
            }
        }
        return best
    }

    /// Forgets the geometry of a range, or of everything.
    public func invalidate(_ range: NSRange?) {
        guard let range else {
            sentenceRanges = nil
            cache.removeAll()
            return
        }
        sentenceRanges = nil
        for (index, layout) in cache where NSIntersectionRange(layout.textRange, range).length > 0
            || layout.textRange.location >= range.location {
            cache.removeValue(forKey: index)
        }
    }

    // MARK: - MarkdownTextStorageObserving

    public func markdownTextStorage(_ storage: MarkdownTextStorage, didRescan range: NSRange) {
        invalidate(range)
    }

    // MARK: - Sentences

    /// Every sentence in the document, paragraph by paragraph.
    private func allSentenceRanges() -> [NSRange] {
        if let sentenceRanges { return sentenceRanges }
        let text = storage.nsText
        var out: [NSRange] = []
        var location = 0
        while location < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            guard paragraph.length > 0 else { break }
            out.append(contentsOf: sentences.sentences(in: paragraph, of: text))
            location = max(NSMaxRange(paragraph), location + 1)
        }
        sentenceRanges = out
        return out
    }

    private func sentenceLayout(index: Int, range: NSRange) -> SentenceLayout? {
        if let cached = cache[index], cached.textRange == range { return cached }
        guard let layoutManager else { return nil }
        ensureLayout(layoutManager)
        let lines = lineRects(for: range, in: layoutManager)
        guard !lines.isEmpty else { return nil }
        let text = storage.nsText
        let wordLayouts = words.words(in: range, of: text).compactMap { word -> WordLayout? in
            let rects = lineRects(for: word, in: layoutManager)
            guard let first = rects.first else { return nil }
            let union = rects.dropFirst().reduce(first) { $0.union($1) }
            return WordLayout(textRange: word, rect: union)
        }
        let layout = SentenceLayout(index: index, textRange: range, lineRects: lines, words: wordLayouts)
        cache[index] = layout
        return layout
    }

    // MARK: - Rectangles

    private func ensureLayout(_ layoutManager: NSTextLayoutManager) {
        layoutManager.ensureLayout(for: layoutManager.documentRange)
    }

    /// One rectangle per line the range covers, in text-container coordinates.
    private func lineRects(for range: NSRange, in layoutManager: NSTextLayoutManager) -> [CGRect] {
        guard let textRange = textRange(range, in: layoutManager) else { return [] }
        var segments: [CGRect] = []
        layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, rect, _, _ in
            if rect.width > 0, rect.height > 0 { segments.append(rect) }
            return true
        }
        return merged(segments)
    }

    /// Joins the segments that share a line into one rectangle.
    private func merged(_ segments: [CGRect]) -> [CGRect] {
        guard !segments.isEmpty else { return [] }
        let sorted = segments.sorted { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }
        var out: [CGRect] = [sorted[0]]
        for rect in sorted.dropFirst() {
            let last = out[out.count - 1]
            if abs(rect.minY - last.minY) < 1 {
                out[out.count - 1] = last.union(rect)
            } else {
                out.append(rect)
            }
        }
        return out
    }

    private func textRange(_ range: NSRange, in layoutManager: NSTextLayoutManager) -> NSTextRange? {
        guard let contentManager = layoutManager.textContentManager,
              let start = contentManager.location(contentManager.documentRange.location, offsetBy: range.location),
              let end = contentManager.location(start, offsetBy: range.length)
        else { return nil }
        return NSTextRange(location: start, end: end)
    }
}

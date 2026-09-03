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
    /// Line rectangles alone, with no word geometry — what a Y-position scan
    /// needs, at a fraction of the cost of a full `SentenceLayout`.
    private var lineRectsCache: [Int: [CGRect]] = [:]
    /// The document length `sentenceRanges` was last valid for, so the next
    /// edit's delta can be recovered without the caller supplying one.
    private var lengthAtLastSegmentation: Int

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
        lengthAtLastSegmentation = storage.length
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
    ///
    /// Scans every sentence's line rectangles — cheap, geometry only — and
    /// builds the full layout, words included, only for whichever sentence
    /// is winning at the time.
    public func nearestSentence(toY y: CGFloat) -> SentenceLayout? {
        guard let layoutManager else { return nil }
        let ranges = allSentenceRanges()
        var bestIndex: Int?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, range) in ranges.enumerated() {
            for rect in cachedLineRects(index: index, range: range, in: layoutManager) {
                let distance = rect.minY > y ? rect.minY - y : (rect.maxY < y ? y - rect.maxY : 0)
                guard distance < bestDistance else { continue }
                bestDistance = distance
                bestIndex = index
            }
        }
        guard let bestIndex else { return nil }
        return sentenceLayout(index: bestIndex, range: ranges[bestIndex])
    }

    /// Forgets the geometry of a range, or of everything.
    public func invalidate(_ range: NSRange?) {
        guard let range else {
            sentenceRanges = nil
            clearGeometryCaches()
            lengthAtLastSegmentation = storage.length
            return
        }
        spliceSentenceRanges(rescanned: range)
        clearGeometryCaches()
        lengthAtLastSegmentation = storage.length
    }

    private func clearGeometryCaches() {
        cache.removeAll()
        lineRectsCache.removeAll()
    }

    // MARK: - MarkdownTextStorageObserving

    public func markdownTextStorage(_ storage: MarkdownTextStorage, didRescan range: NSRange) {
        invalidate(range)
    }

    // MARK: - Sentences

    /// Every sentence in the document, paragraph by paragraph.
    private func allSentenceRanges() -> [NSRange] {
        if let sentenceRanges { return sentenceRanges }
        let out = segment(NSRange(location: 0, length: storage.nsText.length), of: storage.nsText)
        sentenceRanges = out
        lengthAtLastSegmentation = storage.length
        return out
    }

    private func segment(_ range: NSRange, of text: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var location = range.location
        let end = NSMaxRange(range)
        while location < end {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            guard paragraph.length > 0 else { break }
            out.append(contentsOf: sentences.sentences(in: paragraph, of: text))
            location = max(NSMaxRange(paragraph), location + 1)
        }
        return out
    }

    /// Replaces only the sentences the rescan actually touched, instead of
    /// re-segmenting the whole document on every keystroke. A sentence
    /// entirely before the edit is untouched; one entirely after it just
    /// shifts by the edit's delta; the paragraph(s) the rescan covers are
    /// re-segmented fresh.
    private func spliceSentenceRanges(rescanned range: NSRange) {
        guard let existing = sentenceRanges else { return }
        let text = storage.nsText
        let delta = storage.length - lengthAtLastSegmentation

        // Widen to whole paragraphs: a rescan can stop mid-paragraph (the
        // scanner converges on block state, not sentence structure), and a
        // sentence must never be classified against a boundary that splits it.
        let start = text.paragraphRange(for: NSRange(location: range.location, length: 0)).location
        let lastTouched = max(range.location, min(NSMaxRange(range), text.length) - 1)
        let endParagraph = text.paragraphRange(for: NSRange(location: min(lastTouched, max(0, text.length - 1)), length: 0))
        let alignedEnd = max(NSMaxRange(endParagraph), start)
        let oldAffectedEnd = alignedEnd - delta

        let fresh = segment(NSRange(location: start, length: alignedEnd - start), of: text)

        var out: [NSRange] = []
        out.reserveCapacity(existing.count)
        var insertedFresh = false
        for sentence in existing {
            if NSMaxRange(sentence) <= start {
                out.append(sentence)
                continue
            }
            if !insertedFresh {
                out.append(contentsOf: fresh)
                insertedFresh = true
            }
            guard sentence.location >= oldAffectedEnd else { continue }
            out.append(NSRange(location: sentence.location + delta, length: sentence.length))
        }
        if !insertedFresh { out.append(contentsOf: fresh) }
        sentenceRanges = out
    }

    private func sentenceLayout(index: Int, range: NSRange) -> SentenceLayout? {
        if let cached = cache[index], cached.textRange == range { return cached }
        guard let layoutManager else { return nil }
        ensureLayout(for: range, in: layoutManager)
        let lines = cachedLineRects(index: index, range: range, in: layoutManager)
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

    private func cachedLineRects(index: Int, range: NSRange, in layoutManager: NSTextLayoutManager) -> [CGRect] {
        if let cached = lineRectsCache[index] { return cached }
        ensureLayout(for: range, in: layoutManager)
        let rects = lineRects(for: range, in: layoutManager)
        lineRectsCache[index] = rects
        return rects
    }

    /// Lays out only the sentence's own range, not the whole document.
    private func ensureLayout(for range: NSRange, in layoutManager: NSTextLayoutManager) {
        guard let textRange = textRange(range, in: layoutManager) else { return }
        layoutManager.ensureLayout(for: textRange)
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

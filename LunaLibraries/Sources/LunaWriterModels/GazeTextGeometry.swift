//
//  GazeTextGeometry.swift
//  LunaWriterModels
//

import CoreGraphics
import Foundation

/// One word's box, in the text container's coordinate space.
///
/// The container space is scroll-independent: a layout survives scrolling and
/// only changes when the text is re-laid-out. The reading model therefore
/// never sees a scroll as a jump of the reader's eyes.
public struct WordLayout: Equatable {

    /// The word's range in the document's text.
    public var textRange: NSRange

    /// The word's box, in text-container points.
    public var rect: CGRect

    public init(textRange: NSRange, rect: CGRect) {
        self.textRange = textRange
        self.rect = rect
    }

    /// Centre of the box. The sweep compares this to the gaze's x.
    public var centre: CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }
}

/// One sentence's geometry, in the text container's coordinate space.
///
/// A sentence occupies one box per visual line it wraps onto. Vertical distance
/// is measured to the nearest of those lines rather than to the union, so a
/// sentence spanning three lines does not become a tall blur that wins every
/// comparison.
public struct SentenceLayout: Equatable {

    /// Position of the sentence in the document, counting from zero.
    public var index: Int

    /// The sentence's range in the document's text.
    public var textRange: NSRange

    /// One box per visual line the sentence occupies, in reading order.
    public var lineRects: [CGRect]

    /// The sentence's words, in reading order.
    public var words: [WordLayout]

    /// Union of the line boxes, computed once at construction — the reading
    /// model's scoring pass reads this every frame for every candidate
    /// sentence, and `lineRects` never changes after `init`.
    public let bounds: CGRect

    public init(index: Int, textRange: NSRange, lineRects: [CGRect], words: [WordLayout]) {
        self.index = index
        self.textRange = textRange
        self.lineRects = lineRects
        self.words = words
        self.bounds = lineRects.reduce(CGRect.null) { $0.union($1) }
    }

    /// Number of words the sweep has to cross.
    public var wordCount: Int { words.count }

    /// Vertical distance from `y` to the nearest line, zero inside a line.
    public func verticalDistance(to y: CGFloat) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        for rect in lineRects {
            let distance = y < rect.minY ? rect.minY - y : (y > rect.maxY ? y - rect.maxY : 0)
            if distance < best { best = distance }
        }
        return lineRects.isEmpty ? .greatestFiniteMagnitude : best
    }

    /// Horizontal distance from `x` to the sentence's column, zero inside it.
    public func horizontalDistance(to x: CGFloat) -> CGFloat {
        let box = bounds
        guard !box.isNull else { return .greatestFiniteMagnitude }
        return x < box.minX ? box.minX - x : (x > box.maxX ? x - box.maxX : 0)
    }

    /// The word nearest `point`, and how far away it is.
    ///
    /// Vertical distance counts 1.6× because a gaze one line off is a worse
    /// mistake than a gaze a word early: lines are the axis gaze resolves
    /// least well and confusing them costs a whole sentence.
    public func nearestWord(to point: CGPoint) -> (index: Int, distance: CGFloat)? {
        var bestIndex = -1
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, word) in words.enumerated() {
            let rect = word.rect
            let dx = point.x < rect.minX ? rect.minX - point.x : (point.x > rect.maxX ? point.x - rect.maxX : 0)
            let dy = point.y < rect.minY ? rect.minY - point.y : (point.y > rect.maxY ? point.y - rect.maxY : 0)
            let distance = (dx * dx + (dy * 1.6) * (dy * 1.6)).squareRoot()
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        guard bestIndex >= 0 else { return nil }
        return (bestIndex, bestDistance)
    }

    /// Every word sharing the visual line of `wordIndex`, as a range.
    ///
    /// Two words share a line when their box centres sit within half a word
    /// height of each other. The voice anchor speaks of a line, not a word, so
    /// this is what an utterance is attached to.
    public func lineRange(around wordIndex: Int) -> Range<Int> {
        guard !words.isEmpty else { return 0..<0 }
        let index = min(max(wordIndex, 0), words.count - 1)
        let anchor = words[index].rect
        let tolerance = max(anchor.height * 0.5, 1)
        func sharesLine(_ other: Int) -> Bool {
            abs(words[other].rect.midY - anchor.midY) < tolerance
        }
        var first = index
        var last = index
        while first > 0, sharesLine(first - 1) { first -= 1 }
        while last < words.count - 1, sharesLine(last + 1) { last += 1 }
        return first..<(last + 1)
    }
}

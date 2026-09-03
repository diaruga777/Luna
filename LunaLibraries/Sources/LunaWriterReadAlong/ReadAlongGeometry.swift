//
//  ReadAlongGeometry.swift
//  LunaWriterReadAlong
//

import CoreGraphics
import Foundation
import LunaWriterModels

/// The two conversions between the spaces read-along works in, as arithmetic
/// so a test can drive them with no window attached.
public enum ReadAlongGeometry {

    /// Screen point to text-container point.
    ///
    /// - Parameters:
    ///   - viewportOrigin: the scroll view's origin on screen.
    ///   - contentOffset: the scroll view's content offset.
    ///   - textContainerOrigin: where the text container sits in the content.
    public static func textContainerPoint(
        screenPoint: CGPoint,
        viewportOrigin: CGPoint,
        contentOffset: CGPoint,
        textContainerOrigin: CGPoint
    ) -> CGPoint {
        CGPoint(
            x: screenPoint.x - viewportOrigin.x + contentOffset.x - textContainerOrigin.x,
            y: screenPoint.y - viewportOrigin.y + contentOffset.y - textContainerOrigin.y)
    }

    /// The offset that moves a text-container rect into the host view above
    /// the scroll view's visible area.
    public static func hostOffset(
        contentOffset: CGPoint, textContainerOrigin: CGPoint
    ) -> CGPoint {
        CGPoint(
            x: textContainerOrigin.x - contentOffset.x,
            y: textContainerOrigin.y - contentOffset.y)
    }

    /// The sentence whose band sits nearest `fraction` of the viewport — the
    /// fallback anchor for an utterance spoken while gaze is not tracking.
    public static func sentence(
        nearestViewportFraction fraction: CGFloat,
        in sentences: [SentenceLayout],
        contentOffsetY: CGFloat,
        viewportHeight: CGFloat,
        textContainerOriginY: CGFloat
    ) -> SentenceLayout? {
        guard !sentences.isEmpty else { return nil }
        let target = contentOffsetY + fraction * viewportHeight - textContainerOriginY
        return sentences.min {
            abs($0.bounds.midY - target) < abs($1.bounds.midY - target)
        }
    }

    /// The union of a run of a sentence's words, as a text range.
    public static func textRange(
        ofWords words: Range<Int>, in sentence: SentenceLayout
    ) -> NSRange? {
        let clamped = words.clamped(to: 0..<sentence.words.count)
        guard !clamped.isEmpty else { return nil }
        let start = sentence.words[clamped.lowerBound].textRange.location
        let end = NSMaxRange(sentence.words[clamped.upperBound - 1].textRange)
        return NSRange(location: start, length: max(0, end - start))
    }
}

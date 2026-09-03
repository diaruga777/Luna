//
//  ReadingLayer.swift
//  LunaWriterReadAlong
//

import CoreGraphics
import Foundation
import LunaWriterModels
import UIKit

/// The band under the sentence being read, and the trail over the words
/// already read inside it.
///
/// It says the same thing twice on purpose. The attribute runs are the real
/// rendering, drawn by the editor's own layout pass; the `CAShapeLayer`s in
/// the host view mirror them so the band still shows on a host that composes
/// no rendering layer of its own.
public final class ReadingLayer: NSObject, ReadAlongRenderingLayer {

    public weak var invalidationDelegate: ReadAlongRenderingLayerInvalidating?

    /// The active sentence's range, or nil when nothing is active.
    public private(set) var bandRange: NSRange?
    /// The read part of that sentence.
    public private(set) var trailRange: NSRange?
    /// The sentence index the band is on.
    public private(set) var bandSentence: Int?

    private let bandShape = CAShapeLayer()
    private let trailShape = CAShapeLayer()
    private weak var mirrorHost: UIView?

    public override init() {
        super.init()
        for shape in [bandShape, trailShape] {
            shape.fillRule = .nonZero
            shape.actions = ["path": NSNull(), "fillColor": NSNull(), "opacity": NSNull()]
            shape.isHidden = true
        }
        refreshColours()
    }

    /// Re-resolves the mirror's colours. A `CAShapeLayer` holds a resolved
    /// `CGColor`, so the owner calls this when `LunaSkyTrait` changes.
    public func refreshColours() {
        let traits = mirrorHost?.traitCollection ?? UITraitCollection.current
        let accent = ReadAlongTheme.readingAccent
        bandShape.fillColor = accent
            .withAlphaComponent(ReadAlongTheme.bandAlpha).resolvedColor(with: traits).cgColor
        trailShape.fillColor = accent
            .withAlphaComponent(ReadAlongTheme.trailAlpha).resolvedColor(with: traits).cgColor
    }

    // MARK: - Model

    /// Puts the band on `sentence` and the trail over its first
    /// `readUpToWord + 1` words. A nil sentence clears both.
    public func update(sentence: SentenceLayout?, readUpToWord: Int) {
        let previous = union(bandRange, trailRange)
        guard let sentence else {
            bandRange = nil
            trailRange = nil
            bandSentence = nil
            hideMirror()
            invalidate(previous)
            return
        }
        bandSentence = sentence.index
        bandRange = sentence.textRange
        trailRange = Self.trail(in: sentence, readUpToWord: readUpToWord)
        invalidate(union(previous, union(bandRange, trailRange)))
    }

    public func clear() {
        update(sentence: nil, readUpToWord: -1)
    }

    private static func trail(in sentence: SentenceLayout, readUpToWord: Int) -> NSRange? {
        guard readUpToWord >= 0, !sentence.words.isEmpty else { return nil }
        let last = min(readUpToWord, sentence.words.count - 1)
        let first = sentence.words[0].textRange
        let end = NSMaxRange(sentence.words[last].textRange)
        return NSRange(location: first.location, length: max(0, end - first.location))
    }

    // MARK: - ReadAlongRenderingLayer

    public func attributes(in range: NSRange) -> [(NSRange, [NSAttributedString.Key: Any])] {
        var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
        let accent = ReadAlongTheme.readingAccent
        if let band = bandRange?.intersection(range), band.length > 0 {
            runs.append((band, [
                .backgroundColor: accent.withAlphaComponent(ReadAlongTheme.bandAlpha),
            ]))
        }
        if let trail = trailRange?.intersection(range), trail.length > 0 {
            runs.append((trail, [
                .backgroundColor: accent.withAlphaComponent(ReadAlongTheme.trailAlpha),
            ]))
        }
        return runs
    }

    // MARK: - Mirror

    /// Adds the mirror shapes to `host`. Calling it again moves them.
    public func attach(to host: UIView) {
        mirrorHost = host
        host.layer.addSublayer(bandShape)
        host.layer.addSublayer(trailShape)
        refreshColours()
    }

    public func detach() {
        bandShape.removeFromSuperlayer()
        trailShape.removeFromSuperlayer()
        mirrorHost = nil
    }

    /// Redraws the mirror. `offset` moves a text-container point into the host
    /// view: text-container origin minus the scroll view's content offset.
    public func layoutMirror(sentence: SentenceLayout?, readUpToWord: Int, offset: CGPoint) {
        guard let sentence else {
            hideMirror()
            return
        }
        refreshColours()
        bandShape.path = Self.path(rects: sentence.lineRects, offset: offset, radius: 4)
        bandShape.isHidden = false

        if readUpToWord >= 0, !sentence.words.isEmpty {
            let last = min(readUpToWord, sentence.words.count - 1)
            let rects = sentence.words[0...last].map(\.rect)
            trailShape.path = Self.path(rects: rects, offset: offset, radius: 3)
            trailShape.isHidden = false
        } else {
            trailShape.isHidden = true
        }
    }

    private func hideMirror() {
        bandShape.isHidden = true
        trailShape.isHidden = true
    }

    private static func path(rects: [CGRect], offset: CGPoint, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for rect in rects where rect.width > 0 && rect.height > 0 {
            let moved = rect.offsetBy(dx: offset.x, dy: offset.y)
            path.addPath(UIBezierPath(roundedRect: moved, cornerRadius: radius).cgPath)
        }
        return path
    }

    // MARK: - Invalidation

    private func union(_ first: NSRange?, _ second: NSRange?) -> NSRange? {
        switch (first, second) {
        case (nil, nil): return nil
        case let (value?, nil): return value
        case let (nil, value?): return value
        case let (a?, b?): return a.union(b)
        }
    }

    private func invalidate(_ range: NSRange?) {
        guard let range, range.length > 0 else { return }
        invalidationDelegate?.renderingLayer(self, didInvalidate: range)
    }
}

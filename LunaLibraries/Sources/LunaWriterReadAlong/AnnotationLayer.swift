//
//  AnnotationLayer.swift
//  LunaWriterReadAlong
//

import Foundation
import LunaWriterModels
import UIKit

/// One annotation as the layer draws it: the range it currently occupies in
/// the live text, and the mark's kind.
public struct ResolvedAnnotation: Equatable {
    public let id: AnnotationID
    public let range: NSRange
    public let kind: Annotation.Kind

    public init(id: AnnotationID, range: NSRange, kind: Annotation.Kind) {
        self.id = id
        self.range = range
        self.kind = kind
    }
}

/// Draws the sheet's annotations: an underline in the kind's colour, and a
/// wash for a comment, whose text lives in a note rather than in the text.
public final class AnnotationLayer: NSObject, ReadAlongRenderingLayer {

    public weak var invalidationDelegate: ReadAlongRenderingLayerInvalidating?

    public private(set) var annotations: [ResolvedAnnotation] = []

    public override init() {
        super.init()
    }

    /// Replaces the whole set and invalidates everything either set covered.
    public func setAnnotations(_ items: [ResolvedAnnotation]) {
        let touched = Self.union(of: annotations.map(\.range) + items.map(\.range))
        annotations = items.filter { $0.range.length > 0 }
        invalidate(touched)
    }

    public func add(_ item: ResolvedAnnotation) {
        guard item.range.length > 0 else { return }
        annotations.removeAll { $0.id == item.id }
        annotations.append(item)
        invalidate(item.range)
    }

    public func remove(_ id: AnnotationID) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        let range = annotations[index].range
        annotations.remove(at: index)
        invalidate(range)
    }

    public func removeAll() {
        setAnnotations([])
    }

    /// The topmost annotation covering `location`, or nil. Later marks win, so
    /// a tap reaches the one just made.
    public func annotation(at location: Int) -> ResolvedAnnotation? {
        annotations.last { NSLocationInRange(location, $0.range) }
    }

    // MARK: - ReadAlongRenderingLayer

    public func attributes(in range: NSRange) -> [(NSRange, [NSAttributedString.Key: Any])] {
        var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
        for item in annotations {
            let clipped = item.range.intersection(range)
            guard let clipped, clipped.length > 0 else { continue }
            let colour = ReadAlongTheme.colour(for: item.kind)
            var attributes: [NSAttributedString.Key: Any] = [
                .underlineStyle: NSUnderlineStyle.thick.rawValue,
                .underlineColor: colour,
            ]
            if item.kind == .comment {
                attributes[.backgroundColor] =
                    colour.withAlphaComponent(ReadAlongTheme.commentWashAlpha)
            }
            runs.append((clipped, attributes))
        }
        return runs
    }

    // MARK: - Invalidation

    private static func union(of ranges: [NSRange]) -> NSRange? {
        ranges.reduce(nil) { total, range in
            guard range.length > 0 else { return total }
            guard let total else { return range }
            return total.union(range)
        }
    }

    private func invalidate(_ range: NSRange?) {
        guard let range, range.length > 0 else { return }
        invalidationDelegate?.renderingLayer(self, didInvalidate: range)
    }
}

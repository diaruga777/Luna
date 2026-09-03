//
//  AnnotationLayer.swift
//  LunaWriterEditor
//

import UIKit
import LunaWriterModels

/// One annotation, already resolved to a range in the text as it is now.
public struct ResolvedAnnotation: Equatable {
    public var id: AnnotationID
    public var range: NSRange
    public var kind: Annotation.Kind

    public init(id: AnnotationID, range: NSRange, kind: Annotation.Kind) {
        self.id = id
        self.range = range
        self.kind = kind
    }
}

/// Where the layer reads the annotations it marks.
public protocol AnnotationRangeProviding: AnyObject {
    func resolvedAnnotations(in range: NSRange) -> [ResolvedAnnotation]
}

/// Underlines annotated words in their own colour and washes a comment.
///
/// It writes underline and background keys, which no earlier layer touches, so
/// a mark stays visible on a sentence Focus has dimmed.
public final class AnnotationLayer: RenderingAttributeLayer {

    public let identifier: LayerID = .annotation

    public weak var provider: AnnotationRangeProviding?
    public weak var invalidator: LayerInvalidating?

    public init(provider: AnnotationRangeProviding? = nil) {
        self.provider = provider
    }

    public func contributions(in range: NSRange, text: NSString) -> [RangedAttributes] {
        guard let provider else { return [] }
        return provider.resolvedAnnotations(in: range).map { annotation in
            var attributes: [NSAttributedString.Key: Any] = [
                .underlineStyle: NSUnderlineStyle.thick.rawValue,
                .underlineColor: EditorTheme.annotationColour(for: annotation.kind),
            ]
            if annotation.kind == .comment {
                attributes[.backgroundColor] = EditorTheme.annotationWash(for: .comment)
            }
            return RangedAttributes(range: annotation.range, attributes: attributes)
        }
    }
}

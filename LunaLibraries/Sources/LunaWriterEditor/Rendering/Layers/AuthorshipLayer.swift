//
//  AuthorshipLayer.swift
//  LunaWriterEditor
//

import UIKit
import LunaWriterModels

/// Where the layer reads the spans it tints.
public protocol AuthorshipSpanProviding: AnyObject {
    func authorshipSpans(in range: NSRange) -> [AuthorshipSpan]
}

/// Tints words the writer did not type. The writer's own words are never
/// tinted, so a document nobody pasted into looks untouched.
public final class AuthorshipLayer: RenderingAttributeLayer {

    public let identifier: LayerID = .authorship

    public weak var provider: AuthorshipSpanProviding?
    public weak var invalidator: LayerInvalidating?

    public var isEnabled: Bool = true {
        didSet {
            guard isEnabled != oldValue else { return }
            invalidator?.invalidate(nil)
        }
    }

    public init(provider: AuthorshipSpanProviding? = nil) {
        self.provider = provider
    }

    public func contributions(in range: NSRange, text: NSString) -> [RangedAttributes] {
        guard isEnabled, let provider else { return [] }
        return provider.authorshipSpans(in: range).compactMap { span in
            guard let colour = EditorTheme.authorshipColour(for: span.source) else { return nil }
            return RangedAttributes(range: span.range.nsRange, attributes: [.foregroundColor: colour])
        }
    }
}

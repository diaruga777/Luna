//
//  FocusLayer.swift
//  LunaWriterEditor
//

import UIKit

/// Where the layer reads the range that stays lit.
public protocol FocusRangeProviding: AnyObject {
    /// `nil` means nothing is dimmed.
    var focusRange: NSRange? { get }
}

/// Dims everything outside the focus range.
///
/// It sits after the syntax and authorship layers, so its grey wins the
/// foreground colour they wrote: a dimmed sentence is uniformly quiet.
public final class FocusLayer: RenderingAttributeLayer {

    public let identifier: LayerID = .focus

    public weak var provider: FocusRangeProviding?
    public weak var invalidator: LayerInvalidating?

    public init(provider: FocusRangeProviding? = nil) {
        self.provider = provider
    }

    public func contributions(in range: NSRange, text: NSString) -> [RangedAttributes] {
        guard let focus = provider?.focusRange else { return [] }
        var out: [RangedAttributes] = []
        let dim: [NSAttributedString.Key: Any] = [.foregroundColor: EditorTheme.dimmed]
        let before = NSRange(location: range.location, length: max(0, min(NSMaxRange(range), focus.location) - range.location))
        if before.length > 0 { out.append(RangedAttributes(range: before, attributes: dim)) }
        let afterStart = max(range.location, NSMaxRange(focus))
        let after = NSRange(location: afterStart, length: max(0, NSMaxRange(range) - afterStart))
        if after.length > 0 { out.append(RangedAttributes(range: after, attributes: dim)) }
        return out
    }
}

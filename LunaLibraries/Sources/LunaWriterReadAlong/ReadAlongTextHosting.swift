//
//  ReadAlongTextHosting.swift
//  LunaWriterReadAlong
//

import CoreGraphics
import Foundation
import LunaGaze
import LunaWriterModels
import UIKit

/// A rendering pass the editor composes over its own text.
///
/// The read-along layers describe themselves as attribute runs rather than
/// drawing: the editor's composer asks for the attributes covering the range
/// it is about to draw and merges them with its own. `LunaWriterEditor`
/// adapts its composer to this protocol; the app's composition root joins the
/// two, so neither module imports the other.
public protocol ReadAlongRenderingLayer: AnyObject {
    /// Attribute runs inside `range`, clipped to it. An empty result means
    /// this layer adds nothing there.
    func attributes(in range: NSRange) -> [(NSRange, [NSAttributedString.Key: Any])]
    var invalidationDelegate: ReadAlongRenderingLayerInvalidating? { get set }
}

/// The reader of a rendering layer's changes.
public protocol ReadAlongRenderingLayerInvalidating: AnyObject {
    /// `layer`'s attributes over `range` changed; the text there must be laid
    /// out again.
    func renderingLayer(_ layer: ReadAlongRenderingLayer, didInvalidate range: NSRange)
}

/// The text surface read-along watches, drawn by another module.
///
/// Every geometric answer is stated in ONE space each, and the coordinator
/// converts between them: sentence layouts and the gaze point live in
/// text-container coordinates, `textContainerOrigin()` places that container
/// inside the scroll view's content, and `hostView` is the passthrough layer
/// above the text that overlays and toasts are added to.
public protocol ReadAlongTextHosting: AnyObject {
    /// A view above the text that takes no touches of its own.
    var hostView: UIView { get }
    var scrollView: UIScrollView { get }
    /// Sentence and word geometry, in text-container coordinates.
    func sentenceLayouts() -> [SentenceLayout]
    /// Where the text container sits inside the scroll view's content.
    func textContainerOrigin() -> CGPoint
    func installOverlayLayer(_ layer: ReadAlongRenderingLayer)
    func removeOverlayLayer()
    func anchor(for range: NSRange) -> TextAnchor
    func range(for anchor: TextAnchor) -> NSRange?
    var textLength: Int { get }
}

/// Edit-menu items read-along contributes for a selection.
///
/// The editor owns the menu; it asks this for the read-along half rather than
/// naming annotation kinds itself.
public protocol ReadAlongMenuProviding: AnyObject {
    /// Items for the current selection. An empty selection returns nothing.
    func readAlongMenuElements(for selection: NSRange) -> [UIMenuElement]
}

//
//  RenderingAttributeComposer.swift
//  LunaWriterEditor
//

import UIKit

/// Merges the rendering layers and hands the result to the layout manager.
///
/// Layers are held in precedence order and merged in that order, so a later
/// layer wins a key an earlier one also wrote. Focus therefore dims a word the
/// syntax layer coloured, while an annotation's underline — a different key —
/// survives both.
public final class RenderingAttributeComposer: LayerInvalidating {

    /// One screen of characters beyond the viewport, so a flick lands on text
    /// that is already painted.
    public static let viewportSlack = 2

    private weak var layoutManager: NSTextLayoutManager?
    private let storage: NSTextStorage
    private var ordered: [RenderingAttributeLayer] = []
    private var isApplyScheduled = false

    public weak var viewportProvider: RenderingViewportProviding?

    public init(layoutManager: NSTextLayoutManager?, storage: NSTextStorage) {
        self.layoutManager = layoutManager
        self.storage = storage
        installValidator()
    }

    /// TextKit 2 clears a fragment's rendering attributes whenever it lays
    /// that fragment out again, and an edit invalidates the fragment it
    /// touched. Attributes written between the edit and that layout are
    /// lost, so the layout manager's own validator paints each fragment as
    /// it is laid out. UIKit may have installed a validator of its own; it
    /// runs first and keeps whatever it did.
    private func installValidator() {
        guard let layoutManager else { return }
        let previous = layoutManager.renderingAttributesValidator
        layoutManager.renderingAttributesValidator = { [weak self] manager, fragment in
            previous?(manager, fragment)
            self?.paint(fragment: fragment, in: manager)
        }
    }

    private func paint(fragment: NSTextLayoutFragment, in layoutManager: NSTextLayoutManager) {
        guard let contentManager = layoutManager.textContentManager else { return }
        let origin = contentManager.documentRange.location
        let range = fragment.rangeInElement
        let location = contentManager.offset(from: origin, to: range.location)
        let end = contentManager.offset(from: origin, to: range.endLocation)
        guard end > location else { return }
        paint(NSRange(location: location, length: end - location), in: layoutManager)
    }

    private func paint(_ range: NSRange, in layoutManager: NSTextLayoutManager) {
        let text = storage.string as NSString
        for run in composedRuns(in: range, text: text) {
            guard let textRange = textRange(run.range, in: layoutManager) else { continue }
            layoutManager.setRenderingAttributes(run.attributes, for: textRange)
        }
    }

    // MARK: - Layers

    /// Adds a layer at the end of the precedence order, replacing one that
    /// already holds the id.
    public func addLayer(_ layer: RenderingAttributeLayer) {
        removeLayer(layer.identifier)
        ordered.append(layer)
        invalidate(nil)
    }

    public func removeLayer(_ identifier: LayerID) {
        guard ordered.contains(where: { $0.identifier == identifier }) else { return }
        ordered.removeAll { $0.identifier == identifier }
        invalidate(nil)
    }

    // MARK: - Invalidation

    /// Repaint the visible text on the next run-loop turn. Offscreen text is
    /// composed when scrolling reveals it, so a large paste never needs an
    /// immediate rendering pass over the entire document.
    public func invalidate(_ range: NSRange?) {
        scheduleApply()
    }

    private func scheduleApply() {
        guard !isApplyScheduled else { return }
        isApplyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isApplyScheduled = false
            self.applyNow()
        }
    }

    public func applyNow() {
        guard let viewportProvider, viewportProvider.hasViewport, let layoutManager else { return }
        let whole = NSRange(location: 0, length: storage.length)
        let viewport = NSIntersectionRange(viewportProvider.renderingViewportRange, whole)
        let range = widened(viewport, in: whole)
        guard range.length > 0 else { return }
        paint(range, in: layoutManager)
    }

    private func widened(_ range: NSRange, in whole: NSRange) -> NSRange {
        let slack = range.length * Self.viewportSlack
        let start = max(0, range.location - slack)
        let end = min(whole.length, NSMaxRange(range) + slack)
        return NSRange(location: start, length: max(0, end - start))
    }

    // MARK: - Composition

    /// Apply layers in precedence order to Foundation's attributed run store.
    /// It handles overlapping ranges and splits/coalesces runs for us. The
    /// previous boundary-by-contribution scan was quadratic on large pastes.
    public func composedRuns(in range: NSRange, text: NSString? = nil) -> [RangedAttributes] {
        let string = text ?? (storage.string as NSString)
        let target = NSIntersectionRange(range, NSRange(location: 0, length: string.length))
        guard target.length > 0 else { return [] }
        let composed = NSMutableAttributedString(string: string.substring(with: target))
        composed.beginEditing()
        for layer in ordered {
            for contribution in layer.contributions(in: target, text: string) {
                let clipped = NSIntersectionRange(contribution.range, target)
                guard clipped.length > 0 else { continue }
                composed.addAttributes(contribution.attributes, range: NSRange(
                    location: clipped.location - target.location, length: clipped.length))
            }
        }
        composed.endEditing()
        var runs: [RangedAttributes] = []
        composed.enumerateAttributes(in: NSRange(location: 0, length: composed.length)) { attributes, range, _ in
            runs.append(RangedAttributes(range: NSRange(
                location: target.location + range.location, length: range.length), attributes: attributes))
        }
        return runs
    }

    private func textRange(_ range: NSRange, in layoutManager: NSTextLayoutManager) -> NSTextRange? {
        guard let contentManager = layoutManager.textContentManager,
              let start = contentManager.location(contentManager.documentRange.location, offsetBy: range.location),
              let end = contentManager.location(start, offsetBy: range.length)
        else { return nil }
        return NSTextRange(location: start, end: end)
    }
}

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
    private var pendingRange: NSRange?
    private var isApplyScheduled = false

    public weak var viewportProvider: RenderingViewportProviding?

    public init(layoutManager: NSTextLayoutManager?, storage: NSTextStorage) {
        self.layoutManager = layoutManager
        self.storage = storage
    }

    // MARK: - Layers

    public var layers: [RenderingAttributeLayer] { ordered }

    /// Adds a layer at the end of the precedence order, replacing one that
    /// already holds the id.
    public func addLayer(_ layer: RenderingAttributeLayer) {
        removeLayer(layer.identifier)
        ordered.append(layer)
        invalidate(nil)
    }

    /// Adds a layer just before the layer with `identifier`, or at the end.
    public func addLayer(_ layer: RenderingAttributeLayer, before identifier: LayerID) {
        removeLayer(layer.identifier)
        if let index = ordered.firstIndex(where: { $0.identifier == identifier }) {
            ordered.insert(layer, at: index)
        } else {
            ordered.append(layer)
        }
        invalidate(nil)
    }

    public func removeLayer(_ identifier: LayerID) {
        guard ordered.contains(where: { $0.identifier == identifier }) else { return }
        ordered.removeAll { $0.identifier == identifier }
        invalidate(nil)
    }

    public func layer(_ identifier: LayerID) -> RenderingAttributeLayer? {
        ordered.first { $0.identifier == identifier }
    }

    // MARK: - Invalidation

    /// Asks for another pass. Several calls in one run-loop turn produce one
    /// pass over the union of their ranges.
    public func invalidate(_ range: NSRange?) {
        if let range {
            pendingRange = pendingRange.map { NSUnionRange($0, range) } ?? range
        } else {
            pendingRange = nil
        }
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

    /// Runs the pass at once. The scheduled pass calls this; a test does too.
    public func applyNow() {
        let range = paintRange()
        pendingRange = nil
        guard range.length > 0, let layoutManager else { return }
        let text = storage.string as NSString
        for run in composedRuns(in: range, text: text) {
            guard let textRange = textRange(run.range, in: layoutManager) else { continue }
            layoutManager.setRenderingAttributes(run.attributes, for: textRange)
        }
    }

    /// The viewport plus slack, intersected with the document, and widened to
    /// whatever a layer asked for.
    private func paintRange() -> NSRange {
        let whole = NSRange(location: 0, length: storage.length)
        var range = viewportProvider.map { widened($0.renderingViewportRange, in: whole) } ?? whole
        if let pending = pendingRange {
            range = NSIntersectionRange(NSUnionRange(range, pending), whole)
        }
        return NSIntersectionRange(range, whole)
    }

    private func widened(_ range: NSRange, in whole: NSRange) -> NSRange {
        let slack = range.length * Self.viewportSlack
        let start = max(0, range.location - slack)
        let end = min(whole.length, NSMaxRange(range) + slack)
        return NSRange(location: start, length: max(0, end - start))
    }

    // MARK: - Composition

    /// The merged attributes for `range`, as runs that tile it. Every layer
    /// contributes in order and a later one wins a shared key.
    public func composedRuns(in range: NSRange, text: NSString? = nil) -> [RangedAttributes] {
        let string = text ?? (storage.string as NSString)
        let whole = NSRange(location: 0, length: string.length)
        let target = NSIntersectionRange(range, whole)
        guard target.length > 0 else { return [] }

        var buffer = [[NSAttributedString.Key: Any]](repeating: [:], count: target.length)
        for layer in ordered {
            for contribution in layer.contributions(in: target, text: string) {
                let clipped = NSIntersectionRange(contribution.range, target)
                guard clipped.length > 0 else { continue }
                let start = clipped.location - target.location
                for index in start..<(start + clipped.length) {
                    buffer[index].merge(contribution.attributes) { _, new in new }
                }
            }
        }

        var runs: [RangedAttributes] = []
        var runStart = 0
        for index in 1...target.length {
            let ended = index == target.length || !sameAttributes(buffer[index], buffer[runStart])
            guard ended else { continue }
            runs.append(RangedAttributes(
                range: NSRange(location: target.location + runStart, length: index - runStart),
                attributes: buffer[runStart]))
            runStart = index
        }
        return runs
    }

    private func sameAttributes(
        _ lhs: [NSAttributedString.Key: Any], _ rhs: [NSAttributedString.Key: Any]
    ) -> Bool {
        NSDictionary(dictionary: lhs).isEqual(to: rhs)
    }

    private func textRange(_ range: NSRange, in layoutManager: NSTextLayoutManager) -> NSTextRange? {
        guard let contentManager = layoutManager.textContentManager,
              let start = contentManager.location(contentManager.documentRange.location, offsetBy: range.location),
              let end = contentManager.location(start, offsetBy: range.length)
        else { return nil }
        return NSTextRange(location: start, end: end)
    }
}

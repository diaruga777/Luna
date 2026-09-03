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
    /// Whether the next pass should also repaint the viewport, kept apart
    /// from `pendingRange` so a viewport request never displaces a specific
    /// range a layer asked for, and never gets dropped while the viewport
    /// itself is not resolvable yet.
    private var wantsViewport = false
    private var isApplyScheduled = false

    public weak var viewportProvider: RenderingViewportProviding?

    public init(layoutManager: NSTextLayoutManager?, storage: NSTextStorage) {
        self.layoutManager = layoutManager
        self.storage = storage
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

    /// Asks for another pass. Several calls in one run-loop turn produce one
    /// pass over the union of their ranges. `nil` asks for the viewport.
    public func invalidate(_ range: NSRange?) {
        if let range {
            pendingRange = pendingRange.map { NSUnionRange($0, range) } ?? range
        } else {
            wantsViewport = true
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
        // The viewport is satisfied by this pass only once it actually has
        // one to paint; while it is still nil (no layout pass has run yet,
        // e.g. at viewDidLoad) the request stays pending for the next call
        // instead of painting the whole document as a stand-in.
        if viewportProvider?.hasViewport ?? true {
            wantsViewport = false
        }
        guard range.length > 0, let layoutManager else { return }
        let text = storage.string as NSString
        for run in composedRuns(in: range, text: text) {
            guard let textRange = textRange(run.range, in: layoutManager) else { continue }
            layoutManager.setRenderingAttributes(run.attributes, for: textRange)
        }
    }

    /// The viewport plus slack (once it exists), unioned with whatever
    /// specific range a layer asked for, intersected with the document.
    private func paintRange() -> NSRange {
        let whole = NSRange(location: 0, length: storage.length)
        var range: NSRange?
        if wantsViewport, let viewportProvider, viewportProvider.hasViewport {
            range = widened(viewportProvider.renderingViewportRange, in: whole)
        } else if wantsViewport, viewportProvider == nil {
            // No viewport source at all: there is nothing to bound the pass
            // by, so paint the document, as a caller driving the composer
            // directly (a test) expects.
            range = whole
        }
        if let pending = pendingRange {
            range = range.map { NSUnionRange($0, pending) } ?? pending
        }
        guard let range else { return NSRange(location: 0, length: 0) }
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
    ///
    /// Runs are built from the boundaries the contributions themselves draw
    /// (every contribution's start and end), not one dictionary per
    /// character: a sub-interval between two boundaries is, by
    /// construction, either wholly covered or wholly untouched by any one
    /// contribution, so its merged attributes need computing once.
    public func composedRuns(in range: NSRange, text: NSString? = nil) -> [RangedAttributes] {
        let string = text ?? (storage.string as NSString)
        let whole = NSRange(location: 0, length: string.length)
        let target = NSIntersectionRange(range, whole)
        guard target.length > 0 else { return [] }

        var perLayerContributions: [[RangedAttributes]] = []
        var boundaries: Set<Int> = [target.location, NSMaxRange(target)]
        for layer in ordered {
            var clipped: [RangedAttributes] = []
            for contribution in layer.contributions(in: target, text: string) {
                let range = NSIntersectionRange(contribution.range, target)
                guard range.length > 0 else { continue }
                clipped.append(RangedAttributes(range: range, attributes: contribution.attributes))
                boundaries.insert(range.location)
                boundaries.insert(NSMaxRange(range))
            }
            perLayerContributions.append(clipped)
        }
        let sortedBoundaries = boundaries.sorted()

        var runs: [RangedAttributes] = []
        var runStart = target.location
        var runAttributes: [NSAttributedString.Key: Any] = [:]
        var hasOpenRun = false

        for index in 0..<(sortedBoundaries.count - 1) {
            let segmentStart = sortedBoundaries[index]
            let segmentEnd = sortedBoundaries[index + 1]
            guard segmentEnd > segmentStart else { continue }
            var merged: [NSAttributedString.Key: Any] = [:]
            for contributions in perLayerContributions {
                for contribution in contributions
                where contribution.range.location <= segmentStart && NSMaxRange(contribution.range) >= segmentEnd {
                    merged.merge(contribution.attributes) { _, new in new }
                }
            }
            if hasOpenRun, sameAttributes(merged, runAttributes) { continue }
            if hasOpenRun {
                runs.append(RangedAttributes(
                    range: NSRange(location: runStart, length: segmentStart - runStart), attributes: runAttributes))
            }
            runStart = segmentStart
            runAttributes = merged
            hasOpenRun = true
        }
        if hasOpenRun {
            runs.append(RangedAttributes(
                range: NSRange(location: runStart, length: NSMaxRange(target) - runStart), attributes: runAttributes))
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

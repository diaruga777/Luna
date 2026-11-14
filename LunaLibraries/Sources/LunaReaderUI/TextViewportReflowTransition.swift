//
//  TextViewportReflowTransition.swift
//  LunaReaderUI
//
//  A one-shot TextKit transition used when a large-screen Reader card grows
//  from its portrait card column into a near-full-width viewport. UIKit can
//  animate the viewport bounds, but text reflow normally jumps to its final
//  line breaks. This captures the visible-path glyphs and moves each one from
//  its old laid-out position to its new laid-out position instead.
//

import UIKit

@MainActor
final class TextViewportReflowTransition {

    private struct GlyphMove {
        let view: UIImageView
        let destinationFrame: CGRect
    }

    let destinationContentOffsetY: CGFloat
    var glyphCount: Int { moves.count }
    private let overlay: UIView
    private let moves: [GlyphMove]
    private weak var textView: UITextView?
    private let originalTextAlpha: CGFloat

    private init(
        textView: UITextView,
        overlay: UIView,
        moves: [GlyphMove],
        destinationContentOffsetY: CGFloat,
        originalTextAlpha: CGFloat
    ) {
        self.textView = textView
        self.overlay = overlay
        self.moves = moves
        self.destinationContentOffsetY = destinationContentOffsetY
        self.originalTextAlpha = originalTextAlpha
    }

    /// Builds the destination TextKit layout without disturbing the live text
    /// view. Only glyphs whose old→new path intersects either viewport become
    /// image views; glyphs far above or below remain hypothetical geometry and
    /// cost no layers. A glyph moving out of view still receives its true
    /// offscreen destination, and one moving in begins at its true offscreen
    /// source, so clipping — not fading — decides when it appears.
    static func prepare(
        textView: UITextView,
        in hostView: UIView,
        destinationSize: CGSize,
        destinationTextInsets: UIEdgeInsets,
        destinationAdjustedTopInset: CGFloat,
        originDelta: CGPoint = .zero,
        requiresReflow: Bool = false
    ) -> TextViewportReflowTransition? {
        guard textView.attributedText.length > 0,
              textView.bounds.width > 0,
              destinationSize.width > 0,
              requiresReflow || abs(destinationSize.width - textView.bounds.width) > 0.5
                  || abs(originDelta.y) > 0.5,
              textView.alpha > 0
        else { return nil }

        let sourceManager = textView.layoutManager
        sourceManager.ensureLayout(for: textView.textContainer)

        let storage = NSTextStorage(attributedString: textView.attributedText)
        let destinationManager = NSLayoutManager()
        let destinationContainer = NSTextContainer(
            size: CGSize(
                width: max(
                    1,
                    destinationSize.width
                        - destinationTextInsets.left - destinationTextInsets.right),
                // TextKit/CoreGraphics do not accept CGFloat.greatestFiniteMagnitude
                // as real layout geometry (it eventually produces NaN glyph
                // transforms). Ten million points is still thousands of screens.
                height: 10_000_000))
        destinationContainer.lineFragmentPadding = textView.textContainer.lineFragmentPadding
        destinationContainer.lineBreakMode = textView.textContainer.lineBreakMode
        destinationContainer.maximumNumberOfLines = textView.textContainer.maximumNumberOfLines
        storage.addLayoutManager(destinationManager)
        destinationManager.addTextContainer(destinationContainer)
        destinationManager.ensureLayout(for: destinationContainer)

        let sourceOrigin = textView.convert(textView.bounds.origin, to: hostView)
        let desiredOffset = centerAlignedOffset(
            textView: textView, in: hostView, sourceOrigin: sourceOrigin,
            destinationManager: destinationManager, destinationContainer: destinationContainer,
            destinationSize: destinationSize, destinationInsets: destinationTextInsets,
            originDelta: originDelta)
        let destinationOffset = clampedOffsetY(
            textView: textView,
            destinationManager: destinationManager,
            destinationContainer: destinationContainer,
            destinationInsets: destinationTextInsets,
            destinationAdjustedTopInset: destinationAdjustedTopInset,
            destinationHeight: destinationSize.height,
            desiredOffset: desiredOffset)

        let overlay = UIView(frame: hostView.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = false
        overlay.clipsToBounds = true

        if UIAccessibility.isReduceMotionEnabled {
            return TextViewportReflowTransition(
                textView: textView, overlay: overlay, moves: [],
                destinationContentOffsetY: destinationOffset, originalTextAlpha: textView.alpha)
        }

        let sourceOffset = textView.contentOffset.y
        let destinationViewport = CGRect(origin: originDelta, size: destinationSize)
        let visibleSweep = hostView.bounds.union(destinationViewport).insetBy(dx: -32, dy: -64)
        let sourceVisibleGlyphs = sourceManager.glyphRange(
            forBoundingRect: visibleSweep.offsetBy(
                dx: -sourceOrigin.x - textView.textContainerInset.left,
                dy: sourceOffset - sourceOrigin.y - textView.textContainerInset.top),
            in: textView.textContainer)
        let destinationVisibleGlyphs = destinationManager.glyphRange(
            forBoundingRect: visibleSweep.offsetBy(
                dx: -originDelta.x - destinationTextInsets.left,
                dy: destinationOffset - originDelta.y - destinationTextInsets.top),
            in: destinationContainer)
        let destinationCharacters = destinationManager.characterRange(
            forGlyphRange: destinationVisibleGlyphs, actualGlyphRange: nil)
        let destinationInSource = sourceManager.glyphRange(
            forCharacterRange: destinationCharacters, actualCharacterRange: nil)
        let sweptGlyphs: NSRange
        if sourceVisibleGlyphs.length == 0 {
            sweptGlyphs = destinationInSource
        } else if destinationInSource.length == 0 {
            sweptGlyphs = sourceVisibleGlyphs
        } else {
            sweptGlyphs = NSUnionRange(sourceVisibleGlyphs, destinationInSource)
        }
        var moves: [GlyphMove] = []
        var sourceGlyph = sweptGlyphs.location
        while sourceGlyph < NSMaxRange(sweptGlyphs) {
            var sourceGlyphRange = NSRange(location: sourceGlyph, length: 1)
            let characterRange = sourceManager.characterRange(
                forGlyphRange: sourceGlyphRange, actualGlyphRange: &sourceGlyphRange)
            sourceGlyph = NSMaxRange(sourceGlyphRange)
            guard characterRange.length > 0,
                  NSMaxRange(characterRange) <= storage.length
            else { continue }

            let characters = storage.attributedSubstring(from: characterRange).string
            if characters.unicodeScalars.allSatisfy({
                CharacterSet.whitespacesAndNewlines.contains($0)
            }) { continue }

            let destinationGlyphRange = destinationManager.glyphRange(
                forCharacterRange: characterRange, actualCharacterRange: nil)
            guard destinationGlyphRange.length > 0 else { continue }

            let sourceGlyphRect = sourceManager.boundingRect(
                forGlyphRange: sourceGlyphRange, in: textView.textContainer)
            let destinationGlyphRect = destinationManager.boundingRect(
                forGlyphRange: destinationGlyphRange, in: destinationContainer)
            guard !sourceGlyphRect.isNull, !sourceGlyphRect.isEmpty,
                  !destinationGlyphRect.isNull, !destinationGlyphRect.isEmpty
            else { continue }

            let sourceFrame = sourceGlyphRect.offsetBy(
                dx: textView.textContainerInset.left + sourceOrigin.x,
                dy: textView.textContainerInset.top + sourceOrigin.y - sourceOffset)
            let destinationFrame = destinationGlyphRect.offsetBy(
                dx: destinationTextInsets.left,
                dy: destinationTextInsets.top - destinationOffset)
            let sweptFrame = sourceFrame.union(
                destinationFrame.offsetBy(dx: originDelta.x, dy: originDelta.y))
            guard sweptFrame.intersects(visibleSweep) else { continue }

            guard let image = glyphImage(
                layoutManager: sourceManager,
                glyphRange: sourceGlyphRange,
                glyphRect: sourceGlyphRect)
            else { continue }
            let padding: CGFloat = 1
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleToFill
            imageView.frame = sourceFrame.insetBy(dx: -padding, dy: -padding)
            overlay.addSubview(imageView)
            moves.append(GlyphMove(
                view: imageView,
                destinationFrame: destinationFrame.insetBy(dx: -padding, dy: -padding)))
        }

        let originalTextAlpha = textView.alpha
        if !moves.isEmpty {
            hostView.insertSubview(overlay, aboveSubview: textView)
            textView.alpha = 0
        }
        return TextViewportReflowTransition(
            textView: textView,
            overlay: overlay,
            moves: moves,
            destinationContentOffsetY: destinationOffset,
            originalTextAlpha: originalTextAlpha)
    }

    func animate() {
        for move in moves { move.view.frame = move.destinationFrame }
    }

    func finish() {
        overlay.removeFromSuperview()
        textView?.alpha = originalTextAlpha
    }

    struct AnchorGeometry {
        let characterRange: NSRange
        let screenY: CGFloat
        let sourceIsAtTop: Bool
    }

    /// Anchor the glyph around the upper quarter of the viewport, rather than
    /// raw pixels, so the same passage stays under the reader's eyes as earlier
    /// line wraps expand or contract above it.
    static func anchorGeometry(
        in textView: UITextView,
        layoutManager: NSLayoutManager
    ) -> AnchorGeometry? {
        guard layoutManager.numberOfGlyphs > 0 else { return nil }
        let minOffset = -textView.adjustedContentInset.top
        let sourceIsAtTop = textView.contentOffset.y <= minOffset + 1
        let probeY = max(
            0,
            textView.contentOffset.y + textView.bounds.height * 0.25
                - textView.textContainerInset.top)
        let glyph = min(
            layoutManager.glyphIndex(
                for: CGPoint(x: 1, y: probeY), in: textView.textContainer),
            layoutManager.numberOfGlyphs - 1)
        let glyphRange = NSRange(location: glyph, length: 1)
        let characterRange = layoutManager.characterRange(
            forGlyphRange: glyphRange, actualGlyphRange: nil)
        let rect = layoutManager.boundingRect(
            forGlyphRange: glyphRange, in: textView.textContainer)
        return AnchorGeometry(
            characterRange: characterRange,
            screenY: rect.minY + textView.textContainerInset.top - textView.contentOffset.y,
            sourceIsAtTop: sourceIsAtTop)
    }

    /// The only adjustable part of the destination layout is its vertical
    /// scroll offset. A weighted mean minimizes squared vertical travel, giving
    /// glyphs near the center more influence than those at the viewport edges.
    private static func centerAlignedOffset(
        textView: UITextView,
        in hostView: UIView,
        sourceOrigin: CGPoint,
        destinationManager: NSLayoutManager,
        destinationContainer: NSTextContainer,
        destinationSize: CGSize,
        destinationInsets: UIEdgeInsets,
        originDelta: CGPoint
    ) -> CGFloat? {
        guard textView.contentOffset.y > -textView.adjustedContentInset.top + 1 else { return nil }

        let sourceManager = textView.layoutManager
        let sourceInsets = textView.textContainerInset
        let sourceTextOrigin = CGPoint(
            x: sourceOrigin.x + sourceInsets.left,
            y: sourceOrigin.y + sourceInsets.top - textView.contentOffset.y)
        let viewport = hostView.bounds
        let center = CGPoint(x: viewport.midX, y: viewport.midY)
        let radiusX = max(1, min(viewport.width, destinationSize.width) / 2)
        let radiusY = max(1, min(viewport.height, destinationSize.height) / 3)
        let centerBand = CGRect(
            x: center.x - radiusX, y: center.y - radiusY, width: 2 * radiusX, height: 2 * radiusY)
        let glyphs = sourceManager.glyphRange(
            forBoundingRect: centerBand.offsetBy(dx: -sourceTextOrigin.x, dy: -sourceTextOrigin.y),
            in: textView.textContainer)

        var weightedOffset: CGFloat = 0
        var totalWeight: CGFloat = 0
        for glyph in glyphs.location..<NSMaxRange(glyphs) {
            let sourceRange = NSRange(location: glyph, length: 1)
            let characters = sourceManager.characterRange(forGlyphRange: sourceRange, actualGlyphRange: nil)
            guard characters.length > 0, !sourceManager.propertyForGlyph(at: glyph).contains(.controlCharacter)
            else { continue }
            let source = sourceManager.boundingRect(forGlyphRange: sourceRange, in: textView.textContainer)
                .offsetBy(dx: sourceTextOrigin.x, dy: sourceTextOrigin.y)
            guard !source.isEmpty, centerBand.intersects(source) else { continue }
            let distanceX = (source.midX - center.x) / radiusX
            let distanceY = (source.midY - center.y) / radiusY
            let weight = 1 / (1 + 4 * (distanceX * distanceX + distanceY * distanceY))
            let destinationRange = destinationManager.glyphRange(
                forCharacterRange: characters, actualCharacterRange: nil)
            let destination = destinationManager.boundingRect(
                forGlyphRange: destinationRange, in: destinationContainer)
            guard !destination.isEmpty else { continue }
            weightedOffset += weight * (destination.midY + destinationInsets.top + originDelta.y - source.midY)
            totalWeight += weight
        }
        if totalWeight > 0 { return weightedOffset / totalWeight }
        // Image gaps or an empty center band still need a passage anchor.
        guard let anchor = anchorGeometry(in: textView, layoutManager: sourceManager) else { return nil }
        return offsetForAnchor(anchor, manager: destinationManager, container: destinationContainer,
                               topInset: destinationInsets.top) + originDelta.y
    }

    static func restoredOffset(for anchor: AnchorGeometry, in textView: UITextView) -> CGFloat {
        let desired = anchor.sourceIsAtTop ? nil : offsetForAnchor(
            anchor, manager: textView.layoutManager, container: textView.textContainer,
            topInset: textView.textContainerInset.top)
        return clampedOffsetY(
            textView: textView, destinationManager: textView.layoutManager,
            destinationContainer: textView.textContainer,
            destinationInsets: textView.textContainerInset,
            destinationAdjustedTopInset: textView.adjustedContentInset.top,
            destinationHeight: textView.bounds.height, desiredOffset: desired)
    }

    private static func offsetForAnchor(
        _ anchor: AnchorGeometry, manager: NSLayoutManager, container: NSTextContainer, topInset: CGFloat
    ) -> CGFloat {
        let glyphs = manager.glyphRange(forCharacterRange: anchor.characterRange, actualCharacterRange: nil)
        return manager.boundingRect(forGlyphRange: glyphs, in: container).minY + topInset - anchor.screenY
    }

    private static func clampedOffsetY(
        textView: UITextView,
        destinationManager: NSLayoutManager,
        destinationContainer: NSTextContainer,
        destinationInsets: UIEdgeInsets,
        destinationAdjustedTopInset: CGFloat,
        destinationHeight: CGFloat,
        desiredOffset: CGFloat?
    ) -> CGFloat {
        let minimum = -destinationAdjustedTopInset
        let usedBottom = destinationManager.usedRect(for: destinationContainer).maxY
            + destinationInsets.top + destinationInsets.bottom
        let maximum = max(
            minimum,
            usedBottom + textView.adjustedContentInset.bottom - destinationHeight)
        return min(max(minimum, desiredOffset ?? minimum), maximum)
    }

    private static func glyphImage(
        layoutManager: NSLayoutManager,
        glyphRange: NSRange,
        glyphRect: CGRect
    ) -> UIImage? {
        let padding: CGFloat = 1
        let size = CGSize(
            width: max(1, ceil(glyphRect.width + padding * 2)),
            height: max(1, ceil(glyphRect.height + padding * 2)))
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            context.cgContext.translateBy(
                x: -glyphRect.minX + padding,
                y: -glyphRect.minY + padding)
            layoutManager.drawBackground(forGlyphRange: glyphRange, at: .zero)
            layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: .zero)
        }
    }
}

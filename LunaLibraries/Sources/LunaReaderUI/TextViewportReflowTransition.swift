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
        destinationAdjustedTopInset: CGFloat
    ) -> TextViewportReflowTransition? {
        guard textView.attributedText.length > 0,
              textView.bounds.width > 0,
              destinationSize.width > 0,
              abs(destinationSize.width - textView.bounds.width) > 0.5,
              textView.alpha > 0,
              !UIAccessibility.isReduceMotionEnabled
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

        let anchor = anchorGeometry(in: textView, layoutManager: sourceManager)
        let destinationOffset = destinationOffsetY(
            textView: textView,
            destinationManager: destinationManager,
            destinationContainer: destinationContainer,
            destinationInsets: destinationTextInsets,
            destinationAdjustedTopInset: destinationAdjustedTopInset,
            destinationHeight: destinationSize.height,
            anchor: anchor)

        let overlay = UIView(frame: hostView.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = false
        overlay.clipsToBounds = true

        let sourceOffset = textView.contentOffset.y
        let viewportHeight = max(textView.bounds.height, destinationSize.height)
        let visibleSweep = CGRect(
            x: -32, y: -64,
            width: max(textView.bounds.width, destinationSize.width) + 64,
            height: viewportHeight + 128)
        var moves: [GlyphMove] = []
        var sourceGlyph = 0
        while sourceGlyph < sourceManager.numberOfGlyphs {
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
                dx: textView.textContainerInset.left,
                dy: textView.textContainerInset.top - sourceOffset)
            let destinationFrame = destinationGlyphRect.offsetBy(
                dx: destinationTextInsets.left,
                dy: destinationTextInsets.top - destinationOffset)
            let sweptFrame = sourceFrame.union(destinationFrame)
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

        guard !moves.isEmpty else { return nil }
        let originalTextAlpha = textView.alpha
        hostView.insertSubview(overlay, aboveSubview: textView)
        textView.alpha = 0
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

    private struct AnchorGeometry {
        let characterRange: NSRange
        let screenY: CGFloat
        let sourceIsAtTop: Bool
    }

    /// Anchor the glyph around the upper quarter of the viewport, rather than
    /// raw pixels, so the same passage stays under the reader's eyes as earlier
    /// line wraps expand or contract above it.
    private static func anchorGeometry(
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

    private static func destinationOffsetY(
        textView: UITextView,
        destinationManager: NSLayoutManager,
        destinationContainer: NSTextContainer,
        destinationInsets: UIEdgeInsets,
        destinationAdjustedTopInset: CGFloat,
        destinationHeight: CGFloat,
        anchor: AnchorGeometry?
    ) -> CGFloat {
        let minimum = -destinationAdjustedTopInset
        let usedBottom = destinationManager.usedRect(for: destinationContainer).maxY
            + destinationInsets.top + destinationInsets.bottom
        let maximum = max(
            minimum,
            usedBottom + textView.adjustedContentInset.bottom - destinationHeight)
        guard let anchor, !anchor.sourceIsAtTop else { return minimum }
        let glyphRange = destinationManager.glyphRange(
            forCharacterRange: anchor.characterRange, actualCharacterRange: nil)
        let rect = destinationManager.boundingRect(
            forGlyphRange: glyphRange, in: destinationContainer)
        let desired = rect.minY + destinationInsets.top - anchor.screenY
        return min(max(minimum, desired), maximum)
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

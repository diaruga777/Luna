import UIKit
import CoreText

/// A card's scroll-driven resize must not change lines the reader can already see.
/// Keep their column widths in TextKit itself so selection, links, attachments and
/// reading-position geometry all continue to use the displayed layout.
final class ScrollStableTextContainer: NSTextContainer {
    private struct Line {
        let characters: NSRange
        let width: CGFloat
        let centerOffsetX: CGFloat
        var imageView: UIImageView?
        let imageOrigin: CGPoint
    }
    private var lines: [Line] = []
    private var resolvedColumns: [Int: (width: CGFloat, centerOffsetX: CGFloat)] = [:]
    private var boundaryTypesetter: CTTypesetter?

    /// The destination's readable width, inside a canvas wide enough to hold
    /// old lines without making UITextView shift its drawing origin.
    var columnWidth: CGFloat?

    override var isSimpleRectangularTextContainer: Bool { false }

    var hasPreservedLines: Bool { !lines.isEmpty }

    @discardableResult
    func preserveVisibleLines(in textView: UITextView, presentingLines: Bool = true) -> Bool {
        let manager = textView.layoutManager
        manager.ensureLayout(for: self)
        let viewport = textView.superview.map { $0.convert($0.bounds, to: textView) } ?? textView.bounds
        let visible = viewport.offsetBy(
            dx: -textView.textContainerInset.left, dy: -textView.textContainerInset.top)
        var captured: [Line] = []
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) {
            rect, _, _, glyphs, _ in
            guard rect.intersects(visible) else { return }
            let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let column = self.resolvedColumns[characters.location]
            let width = column?.width ?? rect.width
            let centerOffsetX = column?.centerOffsetX ?? (rect.minX - (self.size.width - width) / 2)
            if let existing = self.lines.first(where: {
                $0.characters == characters && (!presentingLines || $0.imageView != nil)
            }) {
                captured.append(existing)
                return
            }
            if !presentingLines {
                captured.append(Line(characters: characters, width: width, centerOffsetX: centerOffsetX, imageView: nil, imageOrigin: .zero))
                return
            }
            guard let manager = manager as? ScrollStableLayoutManager else { return }
            // TextKit redraws final fragment origins immediately; its canvas does
            // not interpolate those origins with the enclosing card. Give each
            // retained line its own view so UIKit animates both on the same curve.
            let imageRect = manager.boundingRect(forGlyphRange: glyphs, in: self)
                .insetBy(dx: -2, dy: -2)
            guard !imageRect.isEmpty,
                  [imageRect.minX, imageRect.minY, imageRect.width, imageRect.height].allSatisfy({ $0.isFinite })
            else { return }
            var image: UIImage?
            textView.traitCollection.performAsCurrent {
                image = UIGraphicsImageRenderer(size: imageRect.size).image { _ in
                    manager.drawLine(forGlyphRange: glyphs, at: CGPoint(
                        x: -imageRect.minX, y: -imageRect.minY))
                }
            }
            guard let image else { return }
            let imageView = UIImageView(image: image)
            imageView.isUserInteractionEnabled = false
            imageView.frame = imageRect.offsetBy(
                dx: textView.textContainerInset.left, dy: textView.textContainerInset.top)
            textView.addSubview(imageView)
            captured.append(Line(characters: characters, width: width, centerOffsetX: centerOffsetX, imageView: imageView,
                imageOrigin: CGPoint(x: imageRect.minX - rect.minX, y: imageRect.minY - rect.minY)))
        }
        for line in lines where !captured.contains(where: { $0.imageView === line.imageView }) {
            line.imageView?.removeFromSuperview()
        }
        let changed = lines.map(\.characters) != captured.map(\.characters)
        lines = captured
        if changed || presentingLines {
            boundaryTypesetter = nil
            invalidatePreservedLayout(in: textView)
        }
        return changed
    }

    /// Retire departed lines and freeze the newly visible ones BEFORE reflowing
    /// behind the viewport. Even a new full-width line must keep its characters
    /// when the last old narrow line leaves the top of the screen.
    @discardableResult
    func releaseOffscreenLines(in textView: UITextView) -> Bool {
        guard hasPreservedLines else { return false }
        return preserveVisibleLines(in: textView, presentingLines: false)
    }

    func reset(in textView: UITextView) {
        guard hasPreservedLines || columnWidth != nil else { return }
        lines.forEach { $0.imageView?.removeFromSuperview() }
        lines = []
        columnWidth = nil
        resolvedColumns = [:]
        invalidatePreservedLayout(in: textView)
    }

    /// Resolve these frames inside the same animation transaction as the card.
    /// The equal and opposite horizontal motion keeps their screen positions fixed.
    func layoutPreservedLines(in textView: UITextView) {
        guard !lines.isEmpty else { return }
        let manager = textView.layoutManager
        manager.ensureLayout(for: self)
        for line in lines {
            guard let imageView = line.imageView else { continue }
            let glyphs = manager.glyphRange(forCharacterRange: line.characters, actualCharacterRange: nil)
            let fragment = manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            imageView.frame.origin = CGPoint(
                x: fragment.minX + line.imageOrigin.x + textView.textContainerInset.left,
                y: fragment.minY + line.imageOrigin.y + textView.textContainerInset.top)
        }
    }

    /// At the endpoint the live glyphs occupy exactly the line views' frames.
    /// Retain the wrapping policy, but return drawing to TextKit so subsequent
    /// selection, read-aloud highlights and appearance changes stay live.
    func finishLinePresentation(in textView: UITextView) {
        for index in lines.indices {
            lines[index].imageView?.removeFromSuperview()
            lines[index].imageView = nil
        }
        (textView.layoutManager as? ScrollStableLayoutManager)?.preservedCharacters = []
    }

    func invalidatePreservedLayout(in textView: UITextView) {
        (textView.layoutManager as? ScrollStableLayoutManager)?.preservedCharacters = lines.filter { $0.imageView != nil }.map(\.characters)
        if lines.isEmpty {
            boundaryTypesetter = nil
        } else if boundaryTypesetter == nil {
            boundaryTypesetter = CTTypesetterCreateWithAttributedString(textView.textStorage)
        }
        textView.layoutManager.invalidateLayout(
            forCharacterRange: NSRange(location: 0, length: textView.textStorage.length),
            actualCharacterRange: nil)
    }

    override func lineFragmentRect(
        forProposedRect proposedRect: CGRect, at characterIndex: Int,
        writingDirection baseWritingDirection: NSWritingDirection,
        remaining remainingRect: UnsafeMutablePointer<CGRect>?
    ) -> CGRect {
        guard let line = lines.first(where: { NSLocationInRange(characterIndex, $0.characters) }) else {
            var rect = super.lineFragmentRect(
                forProposedRect: proposedRect, at: characterIndex,
                writingDirection: baseWritingDirection, remaining: remainingRect)
            if let columnWidth {
                let leading = rect.minX
                let trailing = max(0, size.width - rect.maxX)
                rect.origin.x = (size.width - columnWidth) / 2 + leading
                rect.size.width = max(1, columnWidth - leading - trailing)
            }
            // Prevent a newly wrapped line above the preserved passage from
            // consuming its first characters, including scripts without spaces.
            if let next = lines.first(where: { $0.characters.location > characterIndex }),
               let typesetter = boundaryTypesetter {
                let length = next.characters.location - characterIndex
                // Only measure the seam's short final line, not an ever-longer
                // substring from every preceding line of a deep reading position.
                let available = Double(max(1, rect.width - lineFragmentPadding * 2))
                let naturalBreak = CTTypesetterSuggestLineBreak(typesetter, characterIndex, available)
                let capacity = CTTypesetterSuggestClusterBreak(typesetter, characterIndex, available)
                // Leave an ordinary full-width row alone when its natural word
                // break already ends at the seam. Otherwise scrolling upward
                // would accumulate unnecessarily shortened fragment rectangles.
                if naturalBreak > length, length <= capacity {
                    let prefix = CTTypesetterCreateLine(typesetter, CFRange(location: characterIndex, length: length))
                    let measured = CGFloat(CTLineGetTypographicBounds(prefix, nil, nil, nil))
                    rect.size.width = min(rect.width, measured + lineFragmentPadding * 2 + 0.01)
                }
            }
            resolvedColumns[characterIndex] = (rect.width, rect.minX - (size.width - rect.width) / 2)
            return rect
        }
        remainingRect?.pointee = .zero
        let rect = CGRect(x: (size.width - line.width) / 2 + line.centerOffsetX, y: proposedRect.minY,
                          width: line.width, height: proposedRect.height)
        resolvedColumns[characterIndex] = (line.width, line.centerOffsetX)
        return rect
    }

}

/// Retained lines are drawn by the container's line views. TextKit still owns
/// their complete layout, hit testing, selection and accessibility geometry.
final class ScrollStableLayoutManager: NSLayoutManager {
    var preservedCharacters: [NSRange] = [] {
        didSet {
            invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textStorage?.length ?? 0))
        }
    }

    func drawLine(forGlyphRange glyphs: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphs, at: origin)
        super.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }

    private func liveGlyphRanges(in requested: NSRange) -> [NSRange] {
        var cursor = requested.location
        var result: [NSRange] = []
        for characters in preservedCharacters {
            let hidden = NSIntersectionRange(requested,
                glyphRange(forCharacterRange: characters, actualCharacterRange: nil))
            guard hidden.length > 0 else { continue }
            if hidden.location > cursor {
                result.append(NSRange(location: cursor, length: hidden.location - cursor))
            }
            cursor = max(cursor, NSMaxRange(hidden))
        }
        if cursor < NSMaxRange(requested) {
            result.append(NSRange(location: cursor, length: NSMaxRange(requested) - cursor))
        }
        return result
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        for range in liveGlyphRanges(in: glyphsToShow) {
            super.drawGlyphs(forGlyphRange: range, at: origin)
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        for range in liveGlyphRanges(in: glyphsToShow) {
            super.drawBackground(forGlyphRange: range, at: origin)
        }
    }
}

import UIKit

/// Freeze the passage already on screen, then transition the following four lines
/// toward the new column. This geometry is fixed for the life of the transition:
/// scrolling reveals lines at their final x, without recentering/reflowing them.
/// TextKit still owns selection, links, attachments and reading positions.
final class ScrollStableTextContainer: NSTextContainer {
    private struct Line {
        let characters: NSRange
        let width: CGFloat
        let columnWidth: CGFloat
        let centerOffsetX: CGFloat
        var imageView: UIImageView?
        let imageOrigin: CGPoint
    }
    private var lines: [Line] = []
    private var resolvedColumnWidths: [Int: CGFloat] = [:]
    private var rampSourceWidth: CGFloat = 0
    private var rampStartY: CGFloat = 0
    private var rampHeight: CGFloat = 1
    private static let rampLineCount: CGFloat = 4

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
            rect, _, _, glyphs, stop in
            guard rect.minY <= visible.maxY else { stop.pointee = true; return }
            let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let width = rect.width
            let sourceColumn = self.resolvedColumnWidths[characters.location] ?? self.size.width
            self.rampSourceWidth = sourceColumn
            let centerOffsetX = rect.minX - (self.size.width - width) / 2
            self.rampStartY = rect.maxY
            self.rampHeight = max(1, rect.height * Self.rampLineCount)
            if !presentingLines || !rect.intersects(visible) {
                captured.append(Line(characters: characters, width: width, columnWidth: sourceColumn, centerOffsetX: centerOffsetX, imageView: nil, imageOrigin: .zero))
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
            captured.append(Line(characters: characters, width: width, columnWidth: sourceColumn, centerOffsetX: centerOffsetX, imageView: imageView,
                imageOrigin: CGPoint(x: imageRect.minX - rect.minX, y: imageRect.minY - rect.minY)))
        }
        lines.forEach { $0.imageView?.removeFromSuperview() }
        let changed = lines.map(\.characters) != captured.map(\.characters)
        lines = captured
        if changed || presentingLines {
            invalidatePreservedLayout(in: textView)
        }
        return changed
    }

    func reset(in textView: UITextView) {
        guard hasPreservedLines || columnWidth != nil else { return }
        lines.forEach { $0.imageView?.removeFromSuperview() }
        lines = []
        columnWidth = nil
        rampSourceWidth = 0
        rampStartY = 0
        resolvedColumnWidths = [:]
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
        textView.layoutManager.invalidateLayout(
            forCharacterRange: NSRange(location: 0, length: textView.textStorage.length),
            actualCharacterRange: nil)
    }

    override func lineFragmentRect(
        forProposedRect proposedRect: CGRect, at characterIndex: Int,
        writingDirection baseWritingDirection: NSWritingDirection,
        remaining remainingRect: UnsafeMutablePointer<CGRect>?
    ) -> CGRect {
        // Captured fragments form a prefix, so binary lookup stays cheap even
        // when a deep reading position retains thousands of earlier lines.
        var low = 0
        var high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(lines[middle].characters) <= characterIndex { low = middle + 1 }
            else { high = middle }
        }
        if low < lines.count, NSLocationInRange(characterIndex, lines[low].characters) {
            let line = lines[low]
            remainingRect?.pointee = .zero
            let rect = CGRect(x: (size.width - line.width) / 2 + line.centerOffsetX, y: proposedRect.minY,
                              width: line.width, height: proposedRect.height)
            if low == lines.count - 1 { rampStartY = rect.maxY }
            resolvedColumnWidths[characterIndex] = line.columnWidth
            return rect
        }
        var rect = super.lineFragmentRect(
            forProposedRect: proposedRect, at: characterIndex,
            writingDirection: baseWritingDirection, remaining: remainingRect)
        resolvedColumnWidths[characterIndex] = size.width
        if let columnWidth {
            let leading = rect.minX
            let trailing = max(0, size.width - rect.maxX)
            let progress = min(1, max(0, (proposedRect.minY - rampStartY + proposedRect.height) / rampHeight))
            let width = rampSourceWidth + (columnWidth - rampSourceWidth) * progress
            resolvedColumnWidths[characterIndex] = width
            rect.origin.x = (size.width - width) / 2 + leading
            rect.size.width = max(1, width - leading - trailing)
        }
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

import UIKit
import CoreText

/// A card's scroll-driven resize must not change lines the reader can already see.
/// Keep their column widths in TextKit itself so selection, links, attachments and
/// reading-position geometry all continue to use the displayed layout.
final class ScrollStableTextContainer: NSTextContainer {
    private struct Line {
        let characters: NSRange
        let width: CGFloat
    }
    private var lines: [Line] = []
    private var boundaryTypesetter: CTTypesetter?

    var hasPreservedLines: Bool { !lines.isEmpty }

    func preserveVisibleLines(in textView: UITextView) {
        let manager = textView.layoutManager
        manager.ensureLayout(for: self)
        let visible = textView.bounds.offsetBy(
            dx: -textView.textContainerInset.left, dy: -textView.textContainerInset.top)
        var captured: [Line] = []
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) {
            rect, _, _, glyphs, _ in
            guard rect.intersects(visible) else { return }
            let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let width = self.lines.first { NSLocationInRange(characters.location, $0.characters) }?.width
                ?? self.size.width
            captured.append(Line(characters: characters, width: width))
        }
        lines = captured
        boundaryTypesetter = nil
        invalidatePreservedLayout(in: textView)
    }

    /// Once an old line has left the viewport it may adopt the current width.
    /// The caller anchors the remaining visible passage around this relayout.
    @discardableResult
    func releaseOffscreenLines(in textView: UITextView) -> Bool {
        guard !lines.isEmpty else { return false }
        let visible = textView.bounds.offsetBy(
            dx: -textView.textContainerInset.left, dy: -textView.textContainerInset.top)
        let count = lines.count
        lines.removeAll { line in
            let glyphs = textView.layoutManager.glyphRange(
                forCharacterRange: line.characters, actualCharacterRange: nil)
            return !textView.layoutManager.boundingRect(forGlyphRange: glyphs, in: self).intersects(visible)
        }
        guard lines.count != count else { return false }
        invalidatePreservedLayout(in: textView)
        return true
    }

    func reset(in textView: UITextView) {
        guard hasPreservedLines else { return }
        lines = []
        invalidatePreservedLayout(in: textView)
    }

    private func invalidatePreservedLayout(in textView: UITextView) {
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
            // Prevent a newly wrapped line above the preserved passage from
            // consuming its first characters, including scripts without spaces.
            if let next = lines.first(where: { $0.characters.location > characterIndex }),
               let typesetter = boundaryTypesetter {
                let length = next.characters.location - characterIndex
                // Only measure the seam's short final line, not an ever-longer
                // substring from every preceding line of a deep reading position.
                let capacity = CTTypesetterSuggestClusterBreak(typesetter, characterIndex, Double(rect.width))
                if length <= capacity {
                    let prefix = CTTypesetterCreateLine(typesetter, CFRange(location: characterIndex, length: length))
                    let measured = CGFloat(CTLineGetTypographicBounds(prefix, nil, nil, nil))
                    rect.size.width = min(rect.width, measured + lineFragmentPadding * 2 + 0.01)
                }
            }
            return rect
        }
        remainingRect?.pointee = .zero
        // Keep wider old lines at the leading edge and clip their trailing
        // edge. Negative fragment origins make UITextView shift the entire
        // text canvas, including new lines, to accommodate their used rect.
        return CGRect(x: max(0, (size.width - line.width) / 2), y: proposedRect.minY,
                      width: line.width, height: proposedRect.height)
    }

}

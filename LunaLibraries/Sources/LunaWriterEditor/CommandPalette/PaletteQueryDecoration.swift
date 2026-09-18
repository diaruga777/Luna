import UIKit

/// Glass behind the live input glyphs. One segment per visual line keeps a
/// wrapped query from boxing in the surrounding prose. No second text input,
/// attributed-storage changes, or replacement caret is involved.
final class PaletteQueryDecoration {
    private var segments: [UIVisualEffectView] = []

    func update(range: NSRange?, in textView: UITextView) {
        guard let range,
              let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
              let end = textView.position(from: start, offset: range.length),
              let textRange = textView.textRange(from: start, to: end) else {
            segments.forEach { $0.removeFromSuperview() }
            segments.removeAll()
            return
        }
        var lines: [CGRect] = []
        let caret = textView.caretRect(for: end)
        let rects = textView.selectionRects(for: textRange).map(\.rect) + [caret]
        for rect in rects where rect.height > 0 && rect.width > 0 {
            if let index = lines.firstIndex(where: { abs($0.midY - rect.midY) < 2 }) {
                lines[index] = lines[index].union(rect)
            } else {
                lines.append(rect)
            }
        }
        while segments.count > lines.count { segments.removeLast().removeFromSuperview() }
        for (index, line) in lines.enumerated() {
            let isNew = index >= segments.count
            if isNew {
                let segment = UIVisualEffectView()
                if #available(iOS 26, *) { segment.cornerConfiguration = .corners(radius: .fixed(10)) }
                else { segment.layer.cornerRadius = 10; segment.clipsToBounds = true }
                segment.isUserInteractionEnabled = false
                segment.accessibilityIdentifier = "writer.commandPalette.queryGlass"
                textView.insertSubview(segment, at: 0)
                segments.append(segment)
            }
            let segment = segments[index]
            // Keep UIKit's text and insertion caret above the glass backdrop.
            textView.sendSubviewToBack(segment)
            segment.frame = line.insetBy(dx: -7, dy: -3).integral
            if isNew {
                let apply = {
                    if #available(iOS 26, *) { segment.effect = UIGlassEffect() }
                    else { segment.effect = UIBlurEffect(style: .systemThinMaterial) }
                }
                if UIAccessibility.isReduceMotionEnabled { apply() }
                else { UIView.animate(withDuration: 0.18, animations: apply) }
            }
        }
    }
}

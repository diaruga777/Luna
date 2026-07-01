//
//  ReaderModeIcons.swift
//  Luna
//

import LunaModels
import UIKit

/// Programmatic glyphs for the reader's mode switcher. Scroll uses an SF Symbol;
/// the chunk-highlight and speed (RSVP) modes use stylized "Abc" marks — one with
/// a highlight behind the letters, one with the RSVP focal reticule above/below —
/// so each mode reads as what it does. All are template images so the segmented
/// control tints them.
public enum ReaderModeIcons {
    private static let size = CGSize(width: 30, height: 22)
    private static let font = UIFont.systemFont(ofSize: 13, weight: .bold)
    private static let sample = "Abc" as NSString

    public static func image(for mode: ReadingListItem.ReaderMode) -> UIImage {
        switch mode {
        case .scroll:
            return UIImage(systemName: "text.alignleft")?
                .withRenderingMode(.alwaysTemplate) ?? UIImage()
        case .highlight:
            return highlightedText()
        case .rsvp:
            return reticuleText()
        case .original:
            return UIImage(systemName: "doc.richtext")?
                .withRenderingMode(.alwaysTemplate) ?? UIImage()
        }
    }

    private static func textOrigin(for textSize: CGSize) -> CGPoint {
        CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2)
    }

    /// "Abc" knocked out of a rounded highlight pill — reads as highlighted text.
    private static func highlightedText() -> UIImage {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
        let textSize = sample.size(withAttributes: attributes)
        let origin = textOrigin(for: textSize)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let inset: CGFloat = 3
            let pill = CGRect(
                x: origin.x - inset, y: origin.y - inset / 2,
                width: textSize.width + inset * 2, height: textSize.height + inset)
            UIColor.black.setFill()
            UIBezierPath(roundedRect: pill, cornerRadius: 4).fill()
            // Clear the letters so the control's background shows through them.
            context.cgContext.setBlendMode(.clear)
            sample.draw(at: origin, withAttributes: attributes)
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    /// "Abc" with short reticule bars centered above and below — the RSVP focus.
    private static func reticuleText() -> UIImage {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
        let textSize = sample.size(withAttributes: attributes)
        let origin = textOrigin(for: textSize)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            sample.draw(at: origin, withAttributes: attributes)
            let markWidth: CGFloat = 2.2
            let markHeight: CGFloat = 4
            let centerX = size.width / 2
            UIColor.black.setFill()
            UIBezierPath(roundedRect: CGRect(
                x: centerX - markWidth / 2, y: 0, width: markWidth, height: markHeight),
                cornerRadius: markWidth / 2).fill()
            UIBezierPath(roundedRect: CGRect(
                x: centerX - markWidth / 2, y: size.height - markHeight,
                width: markWidth, height: markHeight), cornerRadius: markWidth / 2).fill()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }
}

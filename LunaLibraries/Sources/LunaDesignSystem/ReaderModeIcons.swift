//
//  ReaderModeIcons.swift
//  Luna
//

import LunaModels
import UIKit

/// Glyphs for the reader's mode switcher: a rich-text archive for the extracted
/// scrolling reader, fast-forward for RSVP speed reading, and a latitude /
/// longitude globe for the saved original web page. Highlight is retained only
/// for decoding the retired standalone mode. All are template images so the
/// segmented control tints them.
public enum ReaderModeIcons {
    private static let size = CGSize(width: 30, height: 22)
    private static let font = UIFont.systemFont(ofSize: 13, weight: .bold)
    private static let sample = "Abc" as NSString

    public static func image(for mode: SavedItem.ReaderMode) -> UIImage {
        switch mode {
        case .scroll:
            return UIImage(systemName: "doc.richtext")?
                .withRenderingMode(.alwaysTemplate) ?? UIImage()
        case .highlight:
            return highlightedText()
        case .rsvp:
            return UIImage(systemName: "forward.fill")?
                .withRenderingMode(.alwaysTemplate) ?? UIImage()
        case .original:
            return UIImage(systemName: "globe")?
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

}

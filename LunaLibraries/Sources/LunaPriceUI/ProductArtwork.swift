//
//  ProductArtwork.swift
//  LunaPriceUI
//

import LunaDesignSystem
import LunaStorage
import UIKit

/// One product image loader, for every surface that draws a tracked product —
/// the deck's chips and archive artwork, the product card's header, and the
/// share/action extensions' editor. The completion runs on the calling queue
/// when the answer is immediate (there is no picture) and on a background queue
/// when a file had to be decoded.
///
/// It lives in the module rather than the app shell because the extension-hosted
/// editor draws the same header, and an extension has no app shell.
public enum PriceTrackerProductImage {
    /// The tag glyph that stands in for a product with no picture of its own.
    public static var fallback: UIImage { PriceTrackerTagIcon.image(size: 52) }

    public static func load(imageFileName: String?, completion: @escaping (UIImage?) -> Void) {
        guard let imageFileName else {
            completion(nil)
            return
        }
        let path = ReadingListStore.shared.articlesDirectory
            .appendingPathComponent(imageFileName).path
        DispatchQueue.global(qos: .userInitiated).async {
            completion(UIImage(contentsOfFile: path)?.preparingForDisplay())
        }
    }
}

/// The tag silhouette from the Price Tracker app icon, intentionally without
/// the magnifying glass. It is rendered in the app's fixed green identity color.
public enum PriceTrackerTagIcon {
    public static func image(size: CGFloat) -> UIImage {
        let canvas = CGSize(width: size, height: size)
        let renderer = UIGraphicsImageRenderer(size: canvas)
        return renderer.image { context in
            let scale = size / 100
            context.cgContext.scaleBy(x: scale, y: scale)
            let tag = UIBezierPath()
            tag.move(to: CGPoint(x: 30, y: 7))
            tag.addCurve(
                to: CGPoint(x: 53, y: 5),
                controlPoint1: CGPoint(x: 37, y: 5),
                controlPoint2: CGPoint(x: 46, y: 5))
            tag.addCurve(
                to: CGPoint(x: 63, y: 10),
                controlPoint1: CGPoint(x: 57, y: 5),
                controlPoint2: CGPoint(x: 60, y: 7))
            tag.addLine(to: CGPoint(x: 94, y: 43))
            tag.addCurve(
                to: CGPoint(x: 94, y: 58),
                controlPoint1: CGPoint(x: 99, y: 48),
                controlPoint2: CGPoint(x: 99, y: 54))
            tag.addLine(to: CGPoint(x: 59, y: 94))
            tag.addCurve(
                to: CGPoint(x: 44, y: 95),
                controlPoint1: CGPoint(x: 54, y: 99),
                controlPoint2: CGPoint(x: 49, y: 99))
            tag.addLine(to: CGPoint(x: 7, y: 61))
            tag.addCurve(
                to: CGPoint(x: 5, y: 49),
                controlPoint1: CGPoint(x: 3, y: 57),
                controlPoint2: CGPoint(x: 3, y: 53))
            tag.addLine(to: CGPoint(x: 9, y: 20))
            tag.addCurve(
                to: CGPoint(x: 30, y: 7),
                controlPoint1: CGPoint(x: 10, y: 12),
                controlPoint2: CGPoint(x: 18, y: 7))
            tag.close()
            tag.append(UIBezierPath(ovalIn: CGRect(x: 18, y: 18, width: 13, height: 13)))
            tag.usesEvenOddFillRule = true
            LunaSurfacePalette.baseColor(for: .priceTracker).setFill()
            tag.fill()
        }
    }
}

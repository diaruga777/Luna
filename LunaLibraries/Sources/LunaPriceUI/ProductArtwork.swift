//
//  ProductArtwork.swift
//  LunaPriceUI
//

import LunaDesignSystem
import LunaFetch
import LunaModels
import LunaStorage
import SwiftSoup
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
    /// Loads the persisted product artwork, recovering a website-owned image
    /// for trackers made by an older build before images were always collected.
    /// The recovery path is header artwork first, then the site's favicon —
    /// deliberately never Luna's price-tag artwork.
    public static func load(
        imageFileName: String?, pageURL: URL?, completion: @escaping (UIImage?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            if let imageFileName {
                let path = ReadingListStore.shared.articlesDirectory
                    .appendingPathComponent(imageFileName).path
                if let image = UIImage(contentsOfFile: path)?.preparingForDisplay() {
                    completion(image)
                    return
                }
            }
            guard let pageURL else {
                completion(nil)
                return
            }
            Task {
                let data = await ProductTrackerArtwork.fallbackData(for: pageURL)
                completion(data.flatMap(UIImage.init(data:))?.preparingForDisplay())
            }
        }
    }
}

/// Website-owned product artwork collection. The page's product image wins;
/// when it is absent or broken, its social/header image and finally its favicon
/// make sure price-tracking never substitutes a Luna brand glyph for a product.
enum ProductTrackerArtwork {
    private static let maximumBytes = 5 * 1024 * 1024

    static func fetch(primaryURL: URL?, pageURL: URL) async -> Data? {
        if let primaryURL, let data = await imageData(from: primaryURL) { return data }
        return await fallbackData(for: pageURL)
    }

    static func fallbackData(for pageURL: URL) async -> Data? {
        if let headerURL = await headerImageURL(for: pageURL),
           let data = await imageData(from: headerURL) {
            return data
        }
        return await FaviconFetcher().fetchIconData(forPageURL: pageURL)
    }

    private static func headerImageURL(for pageURL: URL) async -> URL? {
        guard let html = try? await ArticleFetcher().fetchHTML(from: pageURL),
              let document = try? SwiftSoup.parse(html, pageURL.absoluteString)
        else { return nil }
        let selectors = [
            "meta[property=og:image]", "meta[name=og:image]",
            "meta[property=twitter:image]", "meta[name=twitter:image]",
            "link[rel=image_src]",
        ]
        for selector in selectors {
            guard let element = try? document.select(selector).first() else { continue }
            let raw = ((try? element.attr("content")) ?? "").isEmpty
                ? ((try? element.attr("href")) ?? "")
                : ((try? element.attr("content")) ?? "")
            if let url = URL(string: raw, relativeTo: pageURL)?.absoluteURL,
               url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" {
                return url
            }
        }
        return nil
    }

    private static func imageData(from url: URL) async -> Data? {
        guard LiveNetworkPolicy.allows(url, context: "ProductTrackerArtwork.imageData") else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue(ArticleFetcher.safariUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count > 512, data.count <= maximumBytes,
              UIImage(data: data) != nil
        else { return nil }
        return data
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

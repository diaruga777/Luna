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
    /// The decode/cache target every consumer of this loader shares — the mini
    /// carousel accessory, the deck's own thumbnail chip and scrub preview, the
    /// archive tray row, and the product detail header. Comfortably larger than
    /// any of them ever renders at (even the widest iPad card), so downsampling
    /// to it never visibly differs from a full decode; it exists to cap memory
    /// on an oversized source photo and to give every caller ONE cached decode
    /// instead of a re-decode per deck reload.
    private static let cacheTargetPointSize = CGSize(width: 900, height: 900)
    private static let cacheTargetScale: CGFloat = 3

    /// Loads the persisted product artwork, recovering a website-owned image
    /// for trackers made by an older build before images were always collected.
    /// The recovery path is header artwork first, then the site's favicon —
    /// deliberately never Luna's price-tag artwork.
    public static func load(
        imageFileName: String?, pageURL: URL?, completion: @escaping (UIImage?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let imageFileName else {
                fetchFallback(pageURL: pageURL, completion: completion)
                return
            }
            let path = SavesStore.shared.articlesDirectory
                .appendingPathComponent(imageFileName).path
            DownsampledImageLoader.load(
                path: path, pointSize: cacheTargetPointSize, scale: cacheTargetScale,
                isStale: { false }
            ) { image in
                if let image {
                    completion(image)
                } else {
                    fetchFallback(pageURL: pageURL, completion: completion)
                }
            }
        }
    }

    private static func fetchFallback(pageURL: URL?, completion: @escaping (UIImage?) -> Void) {
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
        guard !URLBehaviorPolicy.pluginsOnly else { return nil }
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

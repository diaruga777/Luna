//
//  MediaPreviewFetcher.swift
//  Clip
//

import ImageIO
import UIKit

/// Fetches a STATIC preview image of the media a social post would save — the
/// poster frame for a video, the image itself for an image post — so the action
/// extension can show what the download will grab. Confirms (via the same resolver
/// the download uses) that downloadable media actually exists, so the caller can
/// gate the download button on a real result.
enum MediaPreviewFetcher {

    /// The outcome of a preview fetch.
    enum Result {
        /// The post exposes no downloadable media — don't offer a download.
        case noMedia
        /// Media exists; `image` is its static preview (nil only if media was found
        /// but the preview image itself couldn't be fetched).
        case media(image: UIImage?)
    }

    /// Resolves the post's media, then loads a downsampled static preview for it.
    static func fetchPreview(
        for url: URL, maxPixelSize: CGFloat,
        resolver: SocialMediaResolving = SocialMediaResolver()
    ) async -> Result {
        let assets = await resolver.resolveAssets(for: url)
        guard let first = assets.first else { return .noMedia }
        guard let previewURL = await previewImageURL(for: url, asset: first) else {
            return .media(image: nil)
        }
        return .media(image: await image(from: previewURL, maxPixelSize: maxPixelSize))
    }

    /// Downloads and downsamples an image (ImageIO) so a full-resolution poster never
    /// sits fully decoded in the memory-constrained extension. Public so callers with
    /// a known image URL (e.g. a YouTube thumbnail) can reuse it.
    static func image(from url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(MediaDownloadHTTP.browserUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// The static-image URL to preview for a resolved asset: a still image previews
    /// itself (at a higher-res variant); a video previews its poster (og:image).
    private static func previewImageURL(for url: URL, asset: MediaAsset) async -> URL? {
        if asset.kind != .video {
            return upgradedStillURL(asset.url)
        }
        // A video's poster comes from the page's og:image, routed through fxtwitter
        // for X (x.com hides og: from crawlers; fxtwitter mirrors it, including the
        // video thumbnail).
        return await ogImageURL(for: posterPageURL(for: url))
    }

    /// The post's Open Graph image — a reliable static poster, served to a
    /// link-unfurler UA even behind a login wall.
    private static func ogImageURL(for url: URL) async -> URL? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("facebookexternalhit/1.1", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else { return nil }
        for pattern in [#"property="og:image:secure_url" content="(.*?)""#,
                        #"property="og:image" content="(.*?)""#] {
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.dotMatchesLineSeparators]) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            guard let match = regex.firstMatch(in: html, range: range), match.numberOfRanges > 1,
                  let group = Range(match.range(at: 1), in: html) else { continue }
            let cleaned = String(html[group]).replacingOccurrences(of: "&amp;", with: "&")
            if let imageURL = URL(string: cleaned) { return imageURL }
        }
        return nil
    }

    /// x.com / twitter.com → fxtwitter.com (same path). fxtwitter serves og:image —
    /// including the video thumbnail — to crawlers, which x.com does not.
    private static func posterPageURL(for url: URL) -> URL {
        let xHosts: Set<String> = [
            "x.com", "www.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com",
        ]
        guard let host = url.host?.lowercased(), xHosts.contains(host),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.host = "fxtwitter.com"
        return components.url ?? url
    }

    /// Twitter media URLs default to a medium size that previews blurry — request the
    /// large variant. Other hosts unchanged.
    private static func upgradedStillURL(_ url: URL) -> URL {
        guard let host = url.host?.lowercased(), host.contains("twimg.com"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        var items = (components.queryItems ?? []).filter { $0.name != "name" }
        items.append(URLQueryItem(name: "name", value: "large"))
        components.queryItems = items
        return components.url ?? url
    }
}

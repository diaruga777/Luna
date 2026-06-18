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
        // A video's preview is its poster (a still); an image/gif previews itself.
        let previewURL: URL? = first.kind == .video ? await ogImageURL(for: url) : first.url
        guard let previewURL else { return .media(image: nil) }
        return .media(image: await downsampledImage(from: previewURL, maxPixelSize: maxPixelSize))
    }

    /// The post's Open Graph image — a reliable static poster across platforms,
    /// served to a link-unfurler UA even behind a login wall.
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

    /// Downloads an image and decodes it downsampled (ImageIO) so a full-resolution
    /// poster never sits decoded in the memory-constrained extension.
    private static func downsampledImage(from url: URL, maxPixelSize: CGFloat) async -> UIImage? {
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
}

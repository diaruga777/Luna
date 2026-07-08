//
//  MediaPreviewFetcher.swift
//  Luna
//

import ImageIO
import UIKit

/// Fetches a downsampled static preview image (e.g. a video thumbnail) so the
/// memory-constrained action extension can show what a download will grab.
public enum MediaPreviewFetcher {

    /// Downloads and downsamples an image (ImageIO) so a full-resolution poster never
    /// sits fully decoded in the memory-constrained extension. Public so callers with
    /// a known image URL can reuse it.
    public static func image(from url: URL, maxPixelSize: CGFloat) async -> UIImage? {
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

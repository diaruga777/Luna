//
//  DownsampledImageLoader.swift
//  Luna
//

import UIKit

/// A shared, cross-feature version of the decode-off-main + NSCache + staleness-token
/// pattern `ReadingListItemCell` pioneered (see its `decodedCache`/`loadToken`). That
/// cell's own implementation is left alone (its timing is snapshot-tested), but any
/// OTHER on-disk-thumbnail consumer — grid cells, viewers, footers — can adopt this
/// instead of writing the pattern a third time.
public enum DownsampledImageLoader {
    /// Decoded, downsampled bitmaps keyed by path + target pixel size, so the same
    /// file requested at two different sizes (e.g. a grid cell and a detail view)
    /// caches both without either evicting the other. Bounded like the cell's own
    /// cache; NSCache also evicts under memory pressure.
    nonisolated(unsafe) private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200
        return cache
    }()

    private static func cacheKey(path: String, maxPixelSize: CGFloat) -> NSString {
        "\(path)#\(Int(maxPixelSize.rounded()))" as NSString
    }

    /// Synchronous cache lookup only — no decode, no queue hop. Lets a caller show an
    /// already-decoded bitmap instantly (no placeholder flash) before falling back to
    /// `load(...)` on a miss, mirroring `ReadingListItemCell.configureArt`.
    public static func cachedImage(path: String, pointSize: CGSize, scale: CGFloat) -> UIImage? {
        cache.object(forKey: cacheKey(path: path, maxPixelSize: maxPixelSize(for: pointSize, scale: scale)))
    }

    /// Loads a thumbnail for `path`, downsampled to `pointSize` at `scale` (see
    /// `ImageDownsampling.decode`), and delivers it on the main thread. A cache hit
    /// delivers synchronously and skips the staleness check (there's nothing stale
    /// about a value the caller could have read via `cachedImage` a moment earlier); a
    /// miss decodes on a utility-QoS background queue and re-checks `isStale()` — which
    /// runs on main, right before delivery — so a slow decode is dropped once the
    /// caller has moved on (a recycled cell, a torn-down view, a paged-away image).
    public static func load(
        path: String, pointSize: CGSize, scale: CGFloat,
        isStale: @escaping () -> Bool,
        completion: @escaping (UIImage?) -> Void
    ) {
        let maxPixel = maxPixelSize(for: pointSize, scale: scale)
        let key = cacheKey(path: path, maxPixelSize: maxPixel)
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            // Re-check the cache on the worker: a sibling caller may have decoded the
            // same file+size while this one was queued behind it.
            let image = cache.object(forKey: key)
                ?? ImageDownsampling.decode(path: path, scale: scale, maxPixelSize: maxPixel)
            if let image { cache.setObject(image, forKey: key) }
            DispatchQueue.main.async {
                guard !isStale() else { return }
                completion(image)
            }
        }
    }

    private static func maxPixelSize(for pointSize: CGSize, scale: CGFloat) -> CGFloat {
        max(pointSize.width, pointSize.height) * max(scale, 1)
    }
}

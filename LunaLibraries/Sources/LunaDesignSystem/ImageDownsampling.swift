//
//  ImageDownsampling.swift
//  Luna
//

import ImageIO
import UIKit

/// Shared ImageIO-based downsampling decode, used anywhere a thumbnail is read
/// from disk (e.g. reading-list row art). Decoding is the slow/expensive part of
/// showing an on-disk image — downsampling to roughly the display size means a
/// large source file (a full-resolution photo, say) is never held as a full-size
/// decoded bitmap for a small well.
public enum ImageDownsampling {
    /// Decodes the image file at `path`, downsampled so its longest side is at
    /// most `maxPixelSize` PIXELS (already scaled for the display). Returns `nil`
    /// if the file is missing or undecodable. Safe to call off the main thread.
    public static func decode(path: String, scale: CGFloat, maxPixelSize: CGFloat) -> UIImage? {
        let url = URL(fileURLWithPath: path)
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        return decode(source: source, scale: scale, maxPixelSize: maxPixelSize)
    }

    /// The same decode for bytes already in memory — a thumbnail that came off the
    /// network and is never written to disk (the import review list's previews).
    /// Safe to call off the main thread.
    public static func decode(data: Data, scale: CGFloat, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        return decode(source: source, scale: scale, maxPixelSize: maxPixelSize)
    }

    private static func decode(
        source: CGImageSource, scale: CGFloat, maxPixelSize: CGFloat
    ) -> UIImage? {
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }
}

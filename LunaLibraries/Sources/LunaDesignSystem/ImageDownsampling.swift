//
//  ImageDownsampling.swift
//  Luna
//

import ImageIO
import UIKit

/// Shared ImageIO-based downsampling decode, used anywhere a thumbnail is read
/// from disk (reading-list row art, catch-up card thumbnails). Decoding is the
/// slow/expensive part of showing an on-disk image — downsampling to roughly the
/// display size means a large source file (a full-resolution photo, say) is never
/// held as a full-size decoded bitmap for a small well.
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

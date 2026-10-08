import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// CPU-side, bounded monochrome encoding. No original image bytes enter a
/// compact EPUB. A 320 × 160 one-bit raster is only 6,400 bytes before PNG
/// compression; the hard encoded ceiling also covers encoder overhead.
public enum CompactEpubBanner {
    public static let maximumWidth = 320
    public static let maximumHeight = 160
    public static let maximumBytes = 8 * 1024

    public static func png(at url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumWidth,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let scale = min(1, min(Double(maximumWidth) / Double(thumbnail.width),
                               Double(maximumHeight) / Double(thumbnail.height)))
        var width = max(1, Int(Double(thumbnail.width) * scale))
        var height = max(1, Int(Double(thumbnail.height) * scale))
        for _ in 0..<4 {
            if let data = encode(thumbnail, width: width, height: height), data.count <= maximumBytes {
                return data
            }
            width = max(1, width / 2)
            height = max(1, height / 2)
        }
        return nil
    }

    private static func encode(_ image: CGImage, width: Int, height: Int) -> Data? {
        let gray = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)

        // Ordered dithering keeps photographs recognizable using only black
        // and white. Pack bits so even noisy images have a small upper bound.
        let matrix = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
        let stride = (width + 7) / 8
        var packed = [UInt8](repeating: 0, count: stride * height)
        for y in 0..<height {
            for x in 0..<width {
                let threshold = matrix[(y % 4) * 4 + x % 4] * 16 + 8
                if Int(pixels[y * width + x]) > threshold {
                    packed[y * stride + x / 8] |= UInt8(1 << (7 - x % 8))
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(packed) as CFData),
              let monochrome = CGImage(width: width, height: height, bitsPerComponent: 1,
                                       bitsPerPixel: 1, bytesPerRow: stride, space: gray,
                                       bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, monochrome, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

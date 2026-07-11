//
//  ScreenshotDigest.swift
//  LunaIntents
//

import CoreGraphics
import ImageIO
import Foundation

/// Pure, CoreGraphics/ImageIO-only screenshot fingerprinting — no UIKit, so
/// it's usable from `LunaIntents` (which the Share/Action extensions link)
/// and unit-testable on macOS. Feeds `ScreenshotDoublePress`'s "is this the
/// same screenshot as last time?" check.
public enum ScreenshotDigest {
    /// The square side (pixels) screenshots are downscaled to before
    /// comparison — small enough to be cheap and to smooth over minor
    /// rendering differences (status-bar clock, Dynamic Island), large
    /// enough to still distinguish genuinely different screens.
    public static let side = 32

    /// Mean-absolute-difference threshold (0–1 scale) below which two
    /// digests are considered the same screenshot. Tuned later on device —
    /// see `claudedocs/app-intents.md`'s on-device QA note.
    public static let similarityThreshold: Double = 0.03

    /// Decodes `data`, draws it into a `side`×`side` 8-bit grayscale
    /// context, and returns the raw pixel bytes (always `side * side` bytes
    /// on success). Returns nil if the data can't be decoded into an image.
    public static func digest(forImageData data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let contextData = context.data else { return nil }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        return Data(bytes: contextData, count: side * side)
    }

    /// Average `|a - b|` per byte, normalized to 0–1. Nil if the two digests
    /// aren't the same size (they always are when both came from `digest
    /// (forImageData:)`, but a caller comparing digests from different
    /// `side`/format eras should get nil rather than a misleading number).
    public static func meanAbsoluteDifference(_ a: Data, _ b: Data) -> Double? {
        guard !a.isEmpty, a.count == b.count else { return nil }
        var total = 0
        a.withUnsafeBytes { aBuffer in
            b.withUnsafeBytes { bBuffer in
                let aBytes = aBuffer.bindMemory(to: UInt8.self)
                let bBytes = bBuffer.bindMemory(to: UInt8.self)
                for index in 0..<aBytes.count {
                    total += abs(Int(aBytes[index]) - Int(bBytes[index]))
                }
            }
        }
        return Double(total) / Double(a.count) / 255.0
    }

    /// True iff `a` and `b` are close enough to count as "the same
    /// screenshot" — used to detect an Action Button double-press so the
    /// second run can skip the model and repeat the first run's save.
    public static func isSimilar(_ a: Data, _ b: Data) -> Bool {
        guard let difference = meanAbsoluteDifference(a, b) else { return false }
        return difference <= similarityThreshold
    }
}

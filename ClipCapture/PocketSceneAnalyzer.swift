//
//  PocketSceneAnalyzer.swift
//  ClipCapture
//

import CoreVideo
import Foundation

/// Decides whether a camera frame looks like the inside of a pocket. This is a cheap
/// luminance/uniformity check rather than a model — instant, deterministic, and runs
/// anywhere (including a locked-capture extension) with no memory pressure.
///
/// Two signals, because auto-exposure fights us: in a dark pocket the camera ramps
/// gain and can *brighten* the frame, so brightness alone can miss. But a pocket is
/// also extremely **uniform** (the lens is covered — no edges or detail). So we treat
/// a frame as a pocket if it's either plainly dark, or dim-and-very-uniform.
struct PocketSceneAnalyzer {

    struct Result {
        /// Mean luminance, 0 (black) … 1 (white).
        let brightness: Double
        /// Fraction of sampled pixels that are near-black.
        let darkFraction: Double
        /// Std deviation of luminance, 0 (perfectly flat) … ~0.5. Low = uniform.
        let uniformityStdDev: Double
        let isPocket: Bool
    }

    /// Plainly dark → pocket regardless of detail.
    var darkBrightnessThreshold: Double = 0.10
    var darkFractionThreshold: Double = 0.80
    /// …or dim-and-flat: AE may have lifted brightness, but a covered lens stays
    /// featureless. Trip when the frame is very uniform and not bright.
    var uniformStdDevThreshold: Double = 0.06
    var dimBrightnessCeiling: Double = 0.35
    /// A pixel is "near-black" below this luminance.
    var nearBlackLuminance: Double = 0.16

    /// Analyzes a 32BGRA pixel buffer by sampling a coarse grid, so it is O(samples)
    /// regardless of resolution.
    func analyze(_ pixelBuffer: CVPixelBuffer) -> Result {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return Result(brightness: 1, darkFraction: 0, uniformityStdDev: 1, isPocket: false)
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        let targetSamplesPerAxis = 64
        let strideX = max(1, width / targetSamplesPerAxis)
        let strideY = max(1, height / targetSamplesPerAxis)

        var sum = 0.0
        var sumSquares = 0.0
        var darkCount = 0
        var samples = 0

        var y = 0
        while y < height {
            let row = y * bytesPerRow
            var x = 0
            while x < width {
                let i = row + x * 4
                // 32BGRA byte order: B, G, R, A.
                let luminance = (0.114 * Double(ptr[i]) + 0.587 * Double(ptr[i + 1]) + 0.299 * Double(ptr[i + 2])) / 255.0
                sum += luminance
                sumSquares += luminance * luminance
                if luminance < nearBlackLuminance { darkCount += 1 }
                samples += 1
                x += strideX
            }
            y += strideY
        }

        guard samples > 0 else {
            return Result(brightness: 1, darkFraction: 0, uniformityStdDev: 1, isPocket: false)
        }
        let n = Double(samples)
        let brightness = sum / n
        let variance = max(0, sumSquares / n - brightness * brightness)
        let stdDev = variance.squareRoot()
        let darkFraction = Double(darkCount) / n

        let plainlyDark = brightness <= darkBrightnessThreshold && darkFraction >= darkFractionThreshold
        let dimAndFlat = stdDev <= uniformStdDevThreshold && brightness <= dimBrightnessCeiling
        return Result(
            brightness: brightness,
            darkFraction: darkFraction,
            uniformityStdDev: stdDev,
            isPocket: plainlyDark || dimAndFlat
        )
    }
}

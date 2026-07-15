#!/usr/bin/env swift

import AppKit
import Foundation

/// Generates monochrome template icons for Luna's three action extensions.
///
/// Each glyph is extracted directly from the foreground artwork in its app's
/// committed 1024px AppIcon master. iOS derives the share-sheet glyph from the
/// PNG alpha channel, so the output is solid black artwork on transparency.

private struct IconVariant {
    let appName: String
    let sourceAppIconName: String
    /// Pixel crop in the 1024px source image, using its top-left coordinate space.
    let crop: NSRect
    let alphaForColor: (_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGFloat
}

private struct IconSlot {
    let filenameSuffix: String
    let pixels: Int
}

private struct ExtractedGlyph {
    let alpha: [UInt8]
    let width: Int
    let height: Int
}

private func smoothstep(_ lower: CGFloat, _ upper: CGFloat, _ value: CGFloat) -> CGFloat {
    let position = max(0, min(1, (value - lower) / (upper - lower)))
    return position * position * (3 - 2 * position)
}

private let variants = [
    IconVariant(
        appName: "Reader",
        sourceAppIconName: "AppIconReader",
        crop: NSRect(x: 128, y: 360, width: 768, height: 485),
        alphaForColor: { red, green, blue in
            // The foreground book is the only bright blue artwork in this crop.
            min(
                smoothstep(0.52, 0.66, blue),
                smoothstep(0.42, 0.55, (red + green + blue) / 3),
                max(
                    smoothstep(0.015, 0.07, blue - red),
                    smoothstep(0.72, 0.92, (red + green + blue) / 3)
                )
            )
        }
    ),
    IconVariant(
        appName: "Downloader",
        sourceAppIconName: "AppIconDownloader",
        crop: NSRect(x: 235, y: 340, width: 554, height: 570),
        alphaForColor: { red, green, blue in
            // Extract the app icon's segmented gold arrow and matching tray.
            min(
                smoothstep(0.62, 0.75, red),
                smoothstep(0.42, 0.55, green),
                smoothstep(0.08, 0.18, red - blue)
            )
        }
    ),
    IconVariant(
        appName: "PriceTracker",
        sourceAppIconName: "AppIconPriceTracker",
        crop: NSRect(x: 250, y: 358, width: 585, height: 562),
        alphaForColor: { red, green, blue in
            // Extract the green tag while retaining its hole and magnifier cutouts.
            min(
                smoothstep(0.65, 0.78, green),
                smoothstep(0.07, 0.18, green - red)
            )
        }
    ),
]

private let slots = [
    IconSlot(filenameSuffix: "20@2x", pixels: 40),
    IconSlot(filenameSuffix: "20@3x", pixels: 60),
    IconSlot(filenameSuffix: "29@2x", pixels: 58),
    IconSlot(filenameSuffix: "29@3x", pixels: 87),
    IconSlot(filenameSuffix: "40@2x", pixels: 80),
    IconSlot(filenameSuffix: "40@3x", pixels: 120),
    IconSlot(filenameSuffix: "60@2x", pixels: 120),
    IconSlot(filenameSuffix: "60@3x", pixels: 180),
    IconSlot(filenameSuffix: "20~ipad", pixels: 20),
    IconSlot(filenameSuffix: "20@2x~ipad", pixels: 40),
    IconSlot(filenameSuffix: "29~ipad", pixels: 29),
    IconSlot(filenameSuffix: "29@2x~ipad", pixels: 58),
    IconSlot(filenameSuffix: "40~ipad", pixels: 40),
    IconSlot(filenameSuffix: "40@2x~ipad", pixels: 80),
    IconSlot(filenameSuffix: "76~ipad", pixels: 76),
    IconSlot(filenameSuffix: "76@2x~ipad", pixels: 152),
    IconSlot(filenameSuffix: "83.5@2x~ipad", pixels: 167),
]

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
private let catalogURL = repositoryRoot.appendingPathComponent("SharedIconAssets.xcassets")

private func sourceBitmap(for variant: IconVariant) throws -> NSBitmapImageRep {
    let filename = "\(variant.sourceAppIconName)-1024.png"
    let sourceURL = catalogURL
        .appendingPathComponent("\(variant.sourceAppIconName).appiconset", isDirectory: true)
        .appendingPathComponent(filename)

    guard
        let data = try? Data(contentsOf: sourceURL),
        let bitmap = NSBitmapImageRep(data: data),
        bitmap.pixelsWide == 1024,
        bitmap.pixelsHigh == 1024
    else {
        throw NSError(
            domain: "LunaActionIconGenerator",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Missing or invalid 1024px app icon: \(sourceURL.path)"]
        )
    }
    return bitmap
}

private func extractedGlyph(for variant: IconVariant) throws -> ExtractedGlyph {
    let source = try sourceBitmap(for: variant)
    let minimumX = Int(variant.crop.minX)
    let minimumY = Int(variant.crop.minY)
    let maximumX = Int(variant.crop.maxX)
    let maximumY = Int(variant.crop.maxY)
    let cropWidth = maximumX - minimumX
    let cropHeight = maximumY - minimumY
    var alpha = [UInt8](repeating: 0, count: cropWidth * cropHeight)

    for sourceY in minimumY ..< maximumY {
        for sourceX in minimumX ..< maximumX {
            guard
                let sourceColor = source.colorAt(x: sourceX, y: sourceY)?.usingColorSpace(.deviceRGB)
            else { continue }

            let value = variant.alphaForColor(
                sourceColor.redComponent,
                sourceColor.greenComponent,
                sourceColor.blueComponent
            ) * sourceColor.alphaComponent
            let byte = UInt8(max(0, min(255, value * 255)).rounded())
            let x = sourceX - minimumX
            let y = sourceY - minimumY
            alpha[y * cropWidth + x] = byte
        }
    }

    var contentMinimumX = cropWidth
    var contentMinimumY = cropHeight
    var contentMaximumX = 0
    var contentMaximumY = 0
    for y in 0 ..< cropHeight {
        for x in 0 ..< cropWidth where alpha[y * cropWidth + x] > 8 {
            contentMinimumX = min(contentMinimumX, x)
            contentMinimumY = min(contentMinimumY, y)
            contentMaximumX = max(contentMaximumX, x)
            contentMaximumY = max(contentMaximumY, y)
        }
    }

    guard contentMinimumX <= contentMaximumX, contentMinimumY <= contentMaximumY else {
        throw NSError(
            domain: "LunaActionIconGenerator",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "No foreground artwork extracted for \(variant.appName)"]
        )
    }

    let glyphWidth = contentMaximumX - contentMinimumX + 1
    let glyphHeight = contentMaximumY - contentMinimumY + 1
    var glyphAlpha = [UInt8](repeating: 0, count: glyphWidth * glyphHeight)
    for y in 0 ..< glyphHeight {
        for x in 0 ..< glyphWidth {
            glyphAlpha[y * glyphWidth + x] = alpha[
                (contentMinimumY + y) * cropWidth + contentMinimumX + x
            ]
        }
    }
    return ExtractedGlyph(alpha: glyphAlpha, width: glyphWidth, height: glyphHeight)
}

private func sampledAlpha(_ glyph: ExtractedGlyph, x: CGFloat, y: CGFloat) -> UInt8 {
    let x0 = max(0, min(glyph.width - 1, Int(floor(x))))
    let y0 = max(0, min(glyph.height - 1, Int(floor(y))))
    let x1 = min(glyph.width - 1, x0 + 1)
    let y1 = min(glyph.height - 1, y0 + 1)
    let xFraction = max(0, min(1, x - CGFloat(x0)))
    let yFraction = max(0, min(1, y - CGFloat(y0)))

    let top = CGFloat(glyph.alpha[y0 * glyph.width + x0]) * (1 - xFraction)
        + CGFloat(glyph.alpha[y0 * glyph.width + x1]) * xFraction
    let bottom = CGFloat(glyph.alpha[y1 * glyph.width + x0]) * (1 - xFraction)
        + CGFloat(glyph.alpha[y1 * glyph.width + x1]) * xFraction
    return UInt8((top * (1 - yFraction) + bottom * yFraction).rounded())
}

private func pngData(glyph: ExtractedGlyph, pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(
            domain: "LunaActionIconGenerator",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Could not allocate \(pixels)x\(pixels) bitmap"]
        )
    }

    bitmap.size = NSSize(width: pixels, height: pixels)
    guard let bitmapData = bitmap.bitmapData else {
        throw NSError(
            domain: "LunaActionIconGenerator",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Could not access bitmap storage"]
        )
    }

    let availableSide = CGFloat(pixels) * 0.72
    let scale = min(
        availableSide / CGFloat(glyph.width),
        availableSide / CGFloat(glyph.height)
    )
    let drawnWidth = max(1, Int((CGFloat(glyph.width) * scale).rounded()))
    let drawnHeight = max(1, Int((CGFloat(glyph.height) * scale).rounded()))
    let offsetX = (pixels - drawnWidth) / 2
    let offsetY = (pixels - drawnHeight) / 2

    for y in 0 ..< drawnHeight {
        for x in 0 ..< drawnWidth {
            let sourceX = (CGFloat(x) + 0.5) / scale - 0.5
            let sourceY = (CGFloat(y) + 0.5) / scale - 0.5
            let alpha = sampledAlpha(glyph, x: sourceX, y: sourceY)
            let byteOffset = (offsetY + y) * bitmap.bytesPerRow
                + (offsetX + x) * bitmap.samplesPerPixel
            bitmapData[byteOffset] = 0
            bitmapData[byteOffset + 1] = 0
            bitmapData[byteOffset + 2] = 0
            bitmapData[byteOffset + 3] = alpha
        }
    }

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(
            domain: "LunaActionIconGenerator",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "Could not encode action icon PNG"]
        )
    }
    return data
}

for variant in variants {
    let glyph = try extractedGlyph(for: variant)
    let setName = "ActionIcon\(variant.appName).appiconset"
    let setURL = catalogURL.appendingPathComponent(setName, isDirectory: true)

    for slot in slots {
        let filename = "ActionIcon\(variant.appName)-\(slot.filenameSuffix).png"
        let outputURL = setURL.appendingPathComponent(filename)
        try pngData(glyph: glyph, pixels: slot.pixels).write(to: outputURL, options: .atomic)
        print(outputURL.path)
    }
}

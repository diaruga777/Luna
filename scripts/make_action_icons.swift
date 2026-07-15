#!/usr/bin/env swift

import AppKit
import Foundation

/// Generates the monochrome template icons used by Luna's three action extensions.
///
/// iOS derives the share-sheet glyph from the PNG alpha channel, so these assets
/// intentionally contain one centered SF Symbol on a transparent canvas. Keep the
/// symbols free of enclosing circles: the share sheet supplies its own circular tile.

private struct IconVariant {
    let appName: String
    let symbolName: String
}

private struct IconSlot {
    let filenameSuffix: String
    let pixels: Int
}

private let variants = [
    IconVariant(appName: "Reader", symbolName: "book.pages.fill"),
    IconVariant(appName: "Downloader", symbolName: "arrow.down.to.line.compact"),
    IconVariant(appName: "PriceTracker", symbolName: "tag.fill"),
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

private func pngData(symbolName: String, pixels: Int) throws -> Data {
    guard let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
        throw NSError(
            domain: "LunaActionIconGenerator",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "SF Symbol not found: \(symbolName)"]
        )
    }

    let canvasSize = NSSize(width: pixels, height: pixels)
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
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Could not allocate \(pixels)x\(pixels) bitmap"]
        )
    }

    bitmap.size = canvasSize
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(
            domain: "LunaActionIconGenerator",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Could not create bitmap graphics context"]
        )
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: canvasSize).fill()

    let configuration = NSImage.SymbolConfiguration(
        pointSize: CGFloat(pixels) * 0.68,
        weight: .semibold
    )
    guard let symbol = baseImage.withSymbolConfiguration(configuration) else {
        NSGraphicsContext.restoreGraphicsState()
        throw NSError(
            domain: "LunaActionIconGenerator",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Could not configure SF Symbol: \(symbolName)"]
        )
    }

    let symbolSize = symbol.size
    let symbolRect = NSRect(
        x: (CGFloat(pixels) - symbolSize.width) / 2,
        y: (CGFloat(pixels) - symbolSize.height) / 2,
        width: symbolSize.width,
        height: symbolSize.height
    )
    symbol.draw(in: symbolRect)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(
            domain: "LunaActionIconGenerator",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG for \(symbolName)"]
        )
    }
    return data
}

for variant in variants {
    let setName = "ActionIcon\(variant.appName).appiconset"
    let setURL = catalogURL.appendingPathComponent(setName, isDirectory: true)

    for slot in slots {
        let filename = "ActionIcon\(variant.appName)-\(slot.filenameSuffix).png"
        let outputURL = setURL.appendingPathComponent(filename)
        try pngData(symbolName: variant.symbolName, pixels: slot.pixels).write(
            to: outputURL,
            options: .atomic
        )
        print(outputURL.path)
    }
}

#!/usr/bin/swift
// Export with Icon Composer's ictool first; flatten only the masked corners for
// the App Store raster, keeping the shared moon and glass rendering untouched.
import AppKit
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: export_writer_icon.swift <ictool-export.png> <repository-root>")
}
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let root = URL(fileURLWithPath: CommandLine.arguments[2])
let image = NSImage(contentsOf: input)!
let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let destinations: [(String, Int)] = [
    ("Luna/Assets.xcassets/AppIconWriter.appiconset/AppIconWriter-1024.png", 1024),
    ("LunaLibraries/Sources/LunaDesignSystem/Resources/LunaAppIconWriter.png", 96),
    ("LunaLibraries/Sources/LunaDesignSystem/Resources/LunaAppIconWriter@2x.png", 192),
    ("LunaLibraries/Sources/LunaDesignSystem/Resources/LunaAppIconWriter@3x.png", 288)
]
for (path, size) in destinations {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let colors = [NSColor(srgbRed: 0.26, green: 0.12, blue: 0.19, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.32, green: 0.24, blue: 0.28, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size), options: [])
    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
    let output = CGImageDestinationCreateWithURL(root.appendingPathComponent(path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(output, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(output))
    print(path)
}

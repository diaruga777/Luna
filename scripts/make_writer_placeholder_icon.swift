#!/usr/bin/env swift
// Draws the PLACEHOLDER Luna Writer icon: a pencil.line glyph on the Luna
// night sky, tinted the Writer's iA-blue surface colour. Writes the 1024px
// appiconset master and the 96pt trio LunaAppIconImage reads for siblings.
// Usage: swift scripts/make_writer_placeholder_icon.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func render(side: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let bounds = NSRect(x: 0, y: 0, width: side, height: side)
    NSColor(calibratedWhite: 0.0, alpha: 1).setFill(); bounds.fill()
    // Faint horizon glow, the family's shared motif.
    let glow = NSGradient(colors: [NSColor(calibratedRed: 30/255, green: 144/255, blue: 255/255, alpha: 0.28), .clear])!
    glow.draw(in: NSRect(x: -side * 0.2, y: -side * 0.55, width: side * 1.4, height: side * 0.9), relativeCenterPosition: .zero)
    let config = NSImage.SymbolConfiguration(pointSize: side * 0.5, weight: .regular)
    if let symbol = NSImage(systemSymbolName: "pencil.line", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor(calibratedWhite: 0.97, alpha: 1).set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let s = tinted.size
        let origin = NSPoint(x: (side - s.width) / 2, y: (side - s.height) / 2)
        tinted.draw(in: NSRect(origin: origin, size: s))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
func write(_ rep: NSBitmapImageRep, to path: String) {
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: root.appendingPathComponent(path))
    print("wrote \(path)")
}
write(render(side: 1024), to: "Luna/Assets.xcassets/AppIconWriter.appiconset/AppIconWriter-1024.png")
write(render(side: 96), to: "LunaLibraries/Sources/LunaDesignSystem/Resources/LunaAppIconWriter.png")
write(render(side: 192), to: "LunaLibraries/Sources/LunaDesignSystem/Resources/LunaAppIconWriter@2x.png")
write(render(side: 288), to: "LunaLibraries/Sources/LunaDesignSystem/Resources/LunaAppIconWriter@3x.png")

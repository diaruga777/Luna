#!/usr/bin/env swift

// Regenerates the action-button Picture-in-Picture guides from the current
// system-settings reference layout. Keep the guide deliberately anonymous:
// this is an instructional mock, not a recording of a person's device.

import AppKit
import AVFoundation
import CoreVideo
import Foundation

private let frameSize = CGSize(width: 440, height: 720)
private let frameRate: Int32 = 30
private let duration: Double = 11

private struct RGB {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    init(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) {
        self.red = red / 255
        self.green = green / 255
        self.blue = blue / 255
        self.alpha = alpha
    }

    var color: CGColor { CGColor(red: red, green: green, blue: blue, alpha: alpha) }
    var nsColor: NSColor { NSColor(red: red, green: green, blue: blue, alpha: alpha) }
}

private enum Appearance {
    case dark
    case light

    var settingsBackground: RGB {
        switch self {
        case .dark: return RGB(0, 0, 0)
        case .light: return RGB(242, 242, 247)
        }
    }

    var groupBackground: RGB {
        switch self {
        case .dark: return RGB(28, 28, 30)
        case .light: return RGB(255, 255, 255)
        }
    }

    var primaryText: RGB {
        switch self {
        case .dark: return RGB(255, 255, 255)
        case .light: return RGB(0, 0, 0)
        }
    }

    var secondaryText: RGB {
        switch self {
        case .dark: return RGB(174, 174, 178)
        case .light: return RGB(110, 110, 115)
        }
    }

    var separator: RGB {
        switch self {
        case .dark: return RGB(57, 57, 59)
        case .light: return RGB(198, 198, 200)
        }
    }

    var chevron: RGB {
        switch self {
        case .dark: return RGB(113, 113, 118)
        case .light: return RGB(142, 142, 147)
        }
    }
}

private struct Surface {
    let name: String
    let iconPath: String
    let resourceStem: String
}

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private let surfaces = [
    Surface(
        name: "Luna",
        iconPath: "SharedIconAssets.xcassets/AppIconLuna.appiconset/AppIconLuna1024.png",
        resourceStem: "ActionButtonGuideLuna"),
    Surface(
        name: "Luna Reader",
        iconPath: "SharedIconAssets.xcassets/AppIconReader.appiconset/AppIconReader-1024.png",
        resourceStem: "ActionButtonGuideReader"),
    Surface(
        name: "Luna Video",
        iconPath: "SharedIconAssets.xcassets/AppIconVideo.appiconset/AppIconVideo-1024.png",
        resourceStem: "ActionButtonGuideDownloader"),
    Surface(
        name: "Luna Price Tracker",
        iconPath: "SharedIconAssets.xcassets/AppIconPriceTracker.appiconset/AppIconPriceTracker-1024.png",
        resourceStem: "ActionButtonGuidePriceTracker"),
]

private final class Canvas {
    let context: CGContext
    let size: CGSize

    init(context: CGContext, size: CGSize) {
        self.context = context
        self.size = size
    }

    func fill(_ color: RGB, rect: CGRect? = nil) {
        context.setFillColor(color.color)
        context.fill(rect ?? CGRect(origin: .zero, size: size))
    }

    func roundedRect(_ rect: CGRect, radius: CGFloat, color: RGB) {
        context.setFillColor(color.color)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    func strokedRoundedRect(_ rect: CGRect, radius: CGFloat, color: RGB, width: CGFloat) {
        context.setStrokeColor(color.color)
        context.setLineWidth(width)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.strokePath()
    }

    func line(from: CGPoint, to: CGPoint, color: RGB, width: CGFloat = 1) {
        context.setStrokeColor(color.color)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.move(to: from)
        context.addLine(to: to)
        context.strokePath()
    }

    func ellipse(_ rect: CGRect, color: RGB) {
        context.setFillColor(color.color)
        context.fillEllipse(in: rect)
    }

    func text(
        _ string: String,
        rect: CGRect,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: RGB,
        alignment: NSTextAlignment = .left,
        lineBreak: NSLineBreakMode = .byWordWrapping
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = lineBreak
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color.nsColor,
            .paragraphStyle: paragraph,
        ]
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        NSAttributedString(string: string, attributes: attributes).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
    }

    func image(_ image: NSImage, rect: CGRect) {
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    func symbol(_ name: String, rect: CGRect, color: RGB, weight: NSFont.Weight = .medium) {
        let configuration = NSImage.SymbolConfiguration(pointSize: rect.height, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color.nsColor]))
        guard let original = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let image = original.withSymbolConfiguration(configuration)
        else { return }
        image.isTemplate = false
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    func gradient(_ rect: CGRect, colors: [RGB], start: CGPoint, end: CGPoint) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors.map(\.color) as CFArray,
            locations: nil)
        else { return }
        context.saveGState()
        context.addRect(rect)
        context.clip()
        context.drawLinearGradient(gradient, start: start, end: end, options: [])
        context.restoreGState()
    }
}

private func drawStatusBar(on canvas: Canvas, appearance: Appearance) {
    let foreground = appearance.primaryText
    canvas.text("9:41", rect: CGRect(x: 28, y: 18, width: 60, height: 20), size: 14, weight: .semibold, color: foreground)
    canvas.symbol("cellularbars", rect: CGRect(x: 333, y: 18, width: 20, height: 14), color: foreground)
    canvas.symbol("wifi", rect: CGRect(x: 361, y: 17, width: 20, height: 15), color: foreground)
    canvas.roundedRect(CGRect(x: 391, y: 18, width: 24, height: 13), radius: 3, color: RGB(48, 209, 88))
    canvas.text("80", rect: CGRect(x: 393, y: 18, width: 19, height: 13), size: 9, weight: .bold, color: RGB(255, 255, 255), alignment: .center)
}

private func iconBackground(for title: String) -> RGB {
    switch title {
    case "Cellular", "Personal Hotspot", "Battery": return RGB(48, 209, 88)
    case "VPN", "Accessibility", "Action Button", "Display & Brightness": return RGB(10, 132, 255)
    case "Appearance": return RGB(0, 0, 0)
    default: return RGB(142, 142, 147)
    }
}

private func symbolName(for title: String) -> String {
    switch title {
    case "Cellular": return "antenna.radiowaves.left.and.right"
    case "Personal Hotspot": return "personalhotspot"
    case "Battery": return "battery.100percent"
    case "VPN": return "globe"
    case "General": return "gearshape"
    case "Accessibility": return "accessibility"
    // The Action Button settings glyph is a bespoke arrow-and-hook mark, not
    // the similarly shaped SF Symbol `arrow.right.to.line`.
    case "Action Button": return ""
    case "Appearance": return "circle.lefthalf.filled"
    case "Camera": return "camera.fill"
    case "Control Center": return "switch.2"
    case "Display & Brightness": return "sun.max.fill"
    default: return "circle"
    }
}

private func drawActionButtonSettingsGlyph(on canvas: Canvas, rect: CGRect) {
    let white = RGB(255, 255, 255)
    let centerY = rect.midY
    let arrowTipX = rect.midX + 0.5
    let hookX = rect.maxX - 3
    let hookTop = rect.minY + 2.5
    let hookBottom = rect.maxY - 2.5

    // Arrow portion.
    canvas.line(
        from: CGPoint(x: rect.minX + 1.5, y: centerY),
        to: CGPoint(x: arrowTipX, y: centerY),
        color: white,
        width: 2.6)
    canvas.line(
        from: CGPoint(x: arrowTipX - 5.2, y: centerY - 5.2),
        to: CGPoint(x: arrowTipX, y: centerY),
        color: white,
        width: 2.6)
    canvas.line(
        from: CGPoint(x: arrowTipX, y: centerY),
        to: CGPoint(x: arrowTipX - 5.2, y: centerY + 5.2),
        color: white,
        width: 2.6)

    // The open, rounded hook to the arrow's right matches the Settings icon.
    let hook = CGMutablePath()
    hook.move(to: CGPoint(x: hookX, y: hookBottom))
    hook.addLine(to: CGPoint(x: hookX, y: hookTop + 3.4))
    hook.addQuadCurve(
        to: CGPoint(x: hookX + 3.4, y: hookTop),
        control: CGPoint(x: hookX, y: hookTop))
    hook.addLine(to: CGPoint(x: rect.maxX - 0.5, y: hookTop))
    canvas.context.setStrokeColor(white.color)
    canvas.context.setLineWidth(2.6)
    canvas.context.setLineCap(.round)
    canvas.context.setLineJoin(.round)
    canvas.context.addPath(hook)
    canvas.context.strokePath()
}

private func drawVPNSettingsGlyph(on canvas: Canvas, rect: CGRect) {
    let white = RGB(255, 255, 255)
    let globeRect = CGRect(x: rect.minX + 1, y: rect.minY, width: rect.width - 2, height: rect.height - 5)
    canvas.symbol("globe", rect: globeRect, color: white)

    // Settings presents VPN as a globe on a small network base.
    let baseY = rect.maxY - 2
    canvas.line(
        from: CGPoint(x: rect.minX + 4, y: baseY),
        to: CGPoint(x: rect.maxX - 4, y: baseY),
        color: white,
        width: 1.8)
    canvas.ellipse(CGRect(x: rect.midX - 2, y: baseY - 2, width: 4, height: 4), color: white)
}

private func drawChevron(on canvas: Canvas, center: CGPoint, color: RGB) {
    canvas.line(from: CGPoint(x: center.x - 4, y: center.y - 7), to: CGPoint(x: center.x + 3, y: center.y), color: color, width: 2.7)
    canvas.line(from: CGPoint(x: center.x + 3, y: center.y), to: CGPoint(x: center.x - 4, y: center.y + 7), color: color, width: 2.7)
}

private func drawSettingsRow(
    on canvas: Canvas,
    title: String,
    row: CGRect,
    appearance: Appearance,
    last: Bool,
    hasToggle: Bool = false
) {
    let iconRect = CGRect(x: row.minX + 16, y: row.midY - 16, width: 32, height: 32)
    canvas.roundedRect(iconRect, radius: 8, color: iconBackground(for: title))
    let symbolRect = iconRect.insetBy(dx: 6, dy: 6)
    if title == "Action Button" {
        drawActionButtonSettingsGlyph(on: canvas, rect: symbolRect)
    } else if title == "VPN" {
        drawVPNSettingsGlyph(on: canvas, rect: symbolRect)
    } else {
        canvas.symbol(symbolName(for: title), rect: symbolRect, color: RGB(255, 255, 255))
    }
    canvas.text(title, rect: CGRect(x: iconRect.maxX + 14, y: row.minY + 11, width: 245, height: 31), size: 20, color: appearance.primaryText)
    if hasToggle {
        canvas.roundedRect(CGRect(x: row.maxX - 62, y: row.midY - 15, width: 48, height: 30), radius: 15, color: RGB(99, 99, 102))
        canvas.ellipse(CGRect(x: row.maxX - 60, y: row.midY - 13, width: 26, height: 26), color: RGB(255, 255, 255))
    } else {
        drawChevron(on: canvas, center: CGPoint(x: row.maxX - 21, y: row.midY), color: appearance.chevron)
    }
    if !last {
        canvas.line(from: CGPoint(x: iconRect.maxX + 14, y: row.maxY), to: CGPoint(x: row.maxX - 16, y: row.maxY), color: appearance.separator)
    }
}

private func drawSettingsScreen(on canvas: Canvas, appearance: Appearance, highlighted: Bool) {
    canvas.fill(appearance.settingsBackground)
    drawStatusBar(on: canvas, appearance: appearance)
    canvas.text("Settings", rect: CGRect(x: 24, y: 62, width: 280, height: 42), size: 32, weight: .bold, color: appearance.primaryText)

    let inset: CGFloat = 16
    let width = frameSize.width - inset * 2
    let topRows = ["Cellular", "Personal Hotspot", "Battery", "VPN"]
    let topGroup = CGRect(x: inset, y: 122, width: width, height: CGFloat(topRows.count) * 54)
    canvas.roundedRect(topGroup, radius: 18, color: appearance.groupBackground)
    for (index, title) in topRows.enumerated() {
        let row = CGRect(x: inset, y: topGroup.minY + CGFloat(index) * 54, width: width, height: 54)
        drawSettingsRow(on: canvas, title: title, row: row, appearance: appearance, last: index == topRows.count - 1, hasToggle: title == "VPN")
    }

    let lowerRows = ["General", "Accessibility", "Action Button", "Appearance", "Camera", "Control Center", "Display & Brightness"]
    let lowerGroup = CGRect(x: inset, y: 362, width: width, height: CGFloat(lowerRows.count) * 54)
    canvas.roundedRect(lowerGroup, radius: 18, color: appearance.groupBackground)
    for (index, title) in lowerRows.enumerated() {
        let row = CGRect(x: inset, y: lowerGroup.minY + CGFloat(index) * 54, width: width, height: 54)
        if highlighted && title == "Action Button" {
            canvas.roundedRect(row.insetBy(dx: 4, dy: 4), radius: 10, color: RGB(10, 132, 255, 0.18))
        }
        drawSettingsRow(on: canvas, title: title, row: row, appearance: appearance, last: index == lowerRows.count - 1)
    }
}

private func drawActionButtonScreen(on canvas: Canvas, surface: Surface) {
    canvas.fill(RGB(0, 0, 0))
    drawStatusBar(on: canvas, appearance: .dark)

    canvas.roundedRect(CGRect(x: 18, y: 60, width: 48, height: 48), radius: 24, color: RGB(35, 35, 37))
    canvas.line(from: CGPoint(x: 46, y: 74), to: CGPoint(x: 33, y: 84), color: RGB(255, 255, 255), width: 3.5)
    canvas.line(from: CGPoint(x: 33, y: 84), to: CGPoint(x: 46, y: 94), color: RGB(255, 255, 255), width: 3.5)

    let strip = CGRect(x: 91, y: 46, width: 258, height: 560)
    canvas.roundedRect(strip, radius: 42, color: RGB(25, 25, 26))
    canvas.gradient(strip, colors: [RGB(19, 19, 20), RGB(83, 84, 87), RGB(20, 20, 21)], start: CGPoint(x: strip.minX, y: strip.midY), end: CGPoint(x: strip.maxX, y: strip.midY))
    canvas.strokedRoundedRect(strip, radius: 42, color: RGB(102, 102, 105), width: 1)

    canvas.symbol("switch.2", rect: CGRect(x: 42, y: 318, width: 32, height: 32), color: RGB(55, 55, 57))
    canvas.strokedRoundedRect(CGRect(x: 365, y: 304, width: 54, height: 54), radius: 27, color: RGB(44, 44, 46), width: 2)
    canvas.symbol("accessibility", rect: CGRect(x: 377, y: 316, width: 30, height: 30), color: RGB(55, 55, 57))

    let button = CGRect(x: 143, y: 160, width: 154, height: 286)
    canvas.roundedRect(button.insetBy(dx: -10, dy: -10), radius: 87, color: RGB(27, 36, 64))
    canvas.roundedRect(button, radius: 77, color: RGB(76, 95, 151))
    canvas.strokedRoundedRect(button, radius: 77, color: RGB(117, 141, 206), width: 1.2)
    if let shortcutsIcon = NSImage(contentsOf: repoRoot.appendingPathComponent("Luna/Resources/ShortcutsAppIcon.png")) {
        canvas.image(shortcutsIcon, rect: CGRect(x: 185, y: 251, width: 70, height: 70))
    }

    let dotY: CGFloat = 483
    for index in 0..<11 {
        let isCurrent = index == 8
        canvas.ellipse(
            CGRect(x: 105 + CGFloat(index) * 23, y: dotY, width: isCurrent ? 11 : 9, height: isCurrent ? 11 : 9),
            color: isCurrent ? RGB(255, 255, 255) : RGB(169, 169, 171))
    }
    canvas.text("Shortcut", rect: CGRect(x: 56, y: 522, width: 328, height: 45), size: 31, weight: .bold, color: RGB(255, 255, 255), alignment: .center)
    canvas.text(
        "Open an app or run your\nfavorite shortcut.",
        rect: CGRect(x: 64, y: 570, width: 312, height: 52),
        size: 18,
        color: RGB(204, 204, 207),
        alignment: .center)

    guard let appIcon = NSImage(contentsOf: repoRoot.appendingPathComponent(surface.iconPath)) else { return }
    let picker = CGRect(x: 85, y: 639, width: 270, height: 50)
    canvas.roundedRect(picker, radius: 25, color: RGB(20, 20, 21))
    canvas.image(appIcon, rect: CGRect(x: picker.minX + 8, y: picker.minY + 7, width: 36, height: 36))
    canvas.text(surface.name, rect: CGRect(x: picker.minX + 55, y: picker.minY + 14, width: 169, height: 23), size: surface.name.count > 16 ? 15 : 18, weight: .semibold, color: RGB(255, 255, 255), lineBreak: .byTruncatingTail)
    canvas.symbol("chevron.up.chevron.down", rect: CGRect(x: picker.maxX - 31, y: picker.minY + 13, width: 17, height: 21), color: RGB(143, 143, 148), weight: .semibold)
}

private func drawShortcutsScreen(on canvas: Canvas, surface: Surface) {
    canvas.fill(RGB(29, 31, 30))
    drawStatusBar(on: canvas, appearance: .dark)
    canvas.roundedRect(CGRect(x: 16, y: 55, width: 408, height: 55), radius: 27, color: RGB(79, 81, 81))
    canvas.symbol("magnifyingglass", rect: CGRect(x: 45, y: 71, width: 22, height: 22), color: RGB(208, 208, 210))
    canvas.text("Search Shortcuts", rect: CGRect(x: 78, y: 69, width: 275, height: 30), size: 22, color: RGB(208, 208, 210))
    canvas.text("My Shortcuts", rect: CGRect(x: 24, y: 151, width: 290, height: 46), size: 31, weight: .bold, color: RGB(255, 255, 255))
    drawChevron(on: canvas, center: CGPoint(x: 330, y: 177), color: RGB(184, 184, 188))

    let width: CGFloat = 184
    let height: CGFloat = 160
    let leftX: CGFloat = 24
    let rightX: CGFloat = 232
    let firstY: CGFloat = 214
    canvas.roundedRect(CGRect(x: leftX, y: firstY, width: width, height: height), radius: 24, color: RGB(0, 194, 172))
    canvas.symbol("square.stack.3d.up.fill", rect: CGRect(x: leftX + 24, y: firstY + 24, width: 42, height: 42), color: RGB(224, 255, 251))
    canvas.text("Show Content", rect: CGRect(x: leftX + 20, y: firstY + 111, width: width - 32, height: 36), size: 20, color: RGB(255, 255, 255))

    let appCard = CGRect(x: rightX, y: firstY, width: width, height: height)
    canvas.roundedRect(appCard, radius: 24, color: RGB(10, 132, 255))
    if let appIcon = NSImage(contentsOf: repoRoot.appendingPathComponent(surface.iconPath)) {
        canvas.image(appIcon, rect: CGRect(x: appCard.minX + 22, y: appCard.minY + 20, width: 48, height: 48))
    }
    canvas.text(surface.name, rect: CGRect(x: appCard.minX + 18, y: appCard.minY + 110, width: width - 28, height: 35), size: surface.name.count > 16 ? 18 : 21, color: RGB(255, 255, 255), lineBreak: .byTruncatingTail)
    canvas.strokedRoundedRect(appCard.insetBy(dx: -4, dy: -4), radius: 28, color: RGB(10, 132, 255), width: 3)

    canvas.roundedRect(CGRect(x: leftX, y: 394, width: width, height: height), radius: 24, color: RGB(174, 104, 227))
    canvas.symbol("folder.fill", rect: CGRect(x: leftX + 22, y: 418, width: 42, height: 34), color: RGB(255, 246, 255))
    canvas.text("Show Folder", rect: CGRect(x: leftX + 20, y: 506, width: width - 32, height: 35), size: 20, color: RGB(255, 255, 255))

    canvas.roundedRect(CGRect(x: rightX, y: 394, width: width, height: height), radius: 24, color: RGB(255, 159, 10))
    canvas.symbol("timer", rect: CGRect(x: rightX + 22, y: 417, width: 42, height: 42), color: RGB(255, 255, 255))
    canvas.text("Set Timer", rect: CGRect(x: rightX + 20, y: 506, width: width - 32, height: 35), size: 20, color: RGB(255, 255, 255))
}

private func sceneWeights(at time: Double) -> (settings: CGFloat, action: CGFloat, shortcuts: CGFloat) {
    switch time {
    case ..<2.25:
        return (1, 0, 0)
    case 2.25..<2.75:
        let progress = CGFloat((time - 2.25) / 0.5)
        return (1 - progress, progress, 0)
    case 2.75..<5.4:
        return (0, 1, 0)
    case 5.4..<5.9:
        let progress = CGFloat((time - 5.4) / 0.5)
        return (0, 1 - progress, progress)
    case 5.9..<8.15:
        return (0, 0, 1)
    case 8.15..<8.65:
        let progress = CGFloat((time - 8.15) / 0.5)
        return (0, progress, 1 - progress)
    default:
        return (0, 1, 0)
    }
}

private func drawFrame(on canvas: Canvas, time: Double, surface: Surface, appearance: Appearance) {
    let weights = sceneWeights(at: time)
    if weights.settings > 0 {
        canvas.context.saveGState()
        canvas.context.setAlpha(weights.settings)
        drawSettingsScreen(on: canvas, appearance: appearance, highlighted: time > 1.7)
        canvas.context.restoreGState()
    }
    if weights.action > 0 {
        canvas.context.saveGState()
        canvas.context.setAlpha(weights.action)
        drawActionButtonScreen(on: canvas, surface: surface)
        canvas.context.restoreGState()
    }
    if weights.shortcuts > 0 {
        canvas.context.saveGState()
        canvas.context.setAlpha(weights.shortcuts)
        drawShortcutsScreen(on: canvas, surface: surface)
        canvas.context.restoreGState()
    }
}

private func pixelBuffer() -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ]
    CVPixelBufferCreate(
        kCFAllocatorDefault,
        Int(frameSize.width),
        Int(frameSize.height),
        kCVPixelFormatType_32BGRA,
        attributes as CFDictionary,
        &buffer)
    return buffer!
}

private func render(pixelBuffer: CVPixelBuffer, time: Double, surface: Surface, appearance: Appearance) {
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    let context = CGContext(
        data: CVPixelBufferGetBaseAddress(pixelBuffer),
        width: Int(frameSize.width),
        height: Int(frameSize.height),
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.setFillColor(RGB(0, 0, 0).color)
    context.fill(CGRect(origin: .zero, size: frameSize))
    context.translateBy(x: 0, y: frameSize.height)
    context.scaleBy(x: 1, y: -1)
    drawFrame(on: Canvas(context: context, size: frameSize), time: time, surface: surface, appearance: appearance)
}

private func writeVideo(to url: URL, surface: Surface, appearance: Appearance) throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: frameSize.width,
        AVVideoHeightKey: frameSize.height,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 750_000,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ],
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: frameSize.width,
            kCVPixelBufferHeightKey as String: frameSize.height,
        ])
    guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)

    let frameCount = Int(duration * Double(frameRate))
    for frame in 0..<frameCount {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
        let buffer = pixelBuffer()
        let time = Double(frame) / Double(frameRate)
        render(pixelBuffer: buffer, time: time, surface: surface, appearance: appearance)
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: frameRate)) else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }
    input.markAsFinished()
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    semaphore.wait()
    if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
}

private func writeAllVideos() throws {
    let resources = repoRoot.appendingPathComponent("Luna/Resources")
    for surface in surfaces {
        for appearance in [Appearance.dark, .light] {
            let suffix = appearance == .dark ? "Dark" : "Light"
            let url = resources.appendingPathComponent("\(surface.resourceStem)\(suffix).mp4")
            print("Writing \(url.lastPathComponent)")
            try writeVideo(to: url, surface: surface, appearance: appearance)
        }
    }
}

do {
    try writeAllVideos()
} catch {
    fputs("Could not generate Action Button guides: \(error)\n", stderr)
    exit(1)
}

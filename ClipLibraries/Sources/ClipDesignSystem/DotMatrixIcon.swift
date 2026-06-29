//
//  DotMatrixIcon.swift
//  ClipDesignSystem
//
//  Renders any glyph (an SF Symbol, or any template `UIImage`) into the app's
//  "Dot Matrix" visual language: the glyph's alpha coverage is sampled over a fine
//  grid and a rounded-square dot is drawn for every covered cell. The result evokes
//  the dot-matrix transition wipes and `DotMatrixSpinnerView` — rounded squares,
//  small spacing, monochrome tint that adapts to light/dark.
//
//  Pure UIKit + Core Graphics (CGContext + a CPU alpha-coverage sample). No Metal,
//  so it is safe in the action/share extensions. Rendered images are cached by
//  (source identity, size, scale, weight, tint, appearance) so repeated layout
//  passes do not re-rasterize.
//
//  The dots are deliberately FINER than the 6pt transition dots: at common 17–24pt
//  nav-bar sizes a 6pt dot would leave only ~3 dots across a glyph and read as mush.
//  We instead pick a per-render dot pitch from the point size so a glyph keeps
//  roughly `targetDotsAcross` cells across its longer side, clamped to a legible
//  range. Dots are sized by their cell's coverage (continuous) which preserves thin
//  strokes far better than a hard on/off threshold.
//

import CoreGraphics
import UIKit

/// Tunable parameters for the dot-matrix glyph renderer. The defaults are picked to
/// stay legible at nav-bar icon sizes; callers can override per-call when needed.
public struct DotMatrixIconStyle: Equatable {
    /// Corner radius of each dot as a fraction of the dot's side (0…0.5). Matches
    /// the spinner's `0.32` rounded-square look.
    public var cornerRadiusFraction: CGFloat
    /// Gap between dots as a fraction of a cell's side (0…1). Smaller than the
    /// spinner's so fine glyphs keep enough ink.
    public var spacingFraction: CGFloat
    /// Roughly how many dot cells should span the glyph's longer drawn side. Higher
    /// = finer/denser dots = more faithful but less obviously "dotted".
    public var targetDotsAcross: CGFloat
    /// Hard floor / ceiling on the dot cell pitch in points, so tiny icons don't get
    /// invisibly fine dots and huge icons don't get cartoonishly chunky ones.
    public var minCellPoints: CGFloat
    public var maxCellPoints: CGFloat
    /// Cells whose coverage is below this are dropped entirely (kills stray
    /// antialiasing crumbs). 0…1.
    public var coverageFloor: CGFloat
    /// A covered cell's dot side scales with coverage between `minDotScale` and 1 of
    /// the available (cell − spacing) size, so partial cells still read as ink but
    /// fully-covered cells fill out. 0…1.
    public var minDotScale: CGFloat

    public init(
        cornerRadiusFraction: CGFloat = 0.32,
        spacingFraction: CGFloat = 0.16,
        targetDotsAcross: CGFloat = 11,
        minCellPoints: CGFloat = 1.4,
        maxCellPoints: CGFloat = 4.0,
        coverageFloor: CGFloat = 0.12,
        minDotScale: CGFloat = 0.45
    ) {
        self.cornerRadiusFraction = cornerRadiusFraction
        self.spacingFraction = spacingFraction
        self.targetDotsAcross = targetDotsAcross
        self.minCellPoints = minCellPoints
        self.maxCellPoints = maxCellPoints
        self.coverageFloor = coverageFloor
        self.minDotScale = minDotScale
    }

    /// The shared default style used by all the convenience helpers.
    public static let standard = DotMatrixIconStyle()
}

/// Renders glyphs into dot-matrix images, with an internal cache.
public enum DotMatrixIcon {

    // MARK: Public API

    /// Build a dot-matrix template image from an SF Symbol.
    ///
    /// - Parameters:
    ///   - systemName: the SF Symbol name.
    ///   - pointSize: the symbol point size to rasterize at (defaults to 17, the
    ///     typical nav-bar glyph size).
    ///   - weight: the symbol weight (heavier reads better as dots).
    ///   - tint: the dot color. Pass `nil` (default) to get an
    ///     `.alwaysTemplate` image that takes the host control's tint; pass a color
    ///     to bake it in (`.alwaysOriginal`).
    ///   - traits: trait collection used to resolve a baked-in tint and pick the
    ///     light/dark cache bucket. Ignored when `tint` is nil.
    ///   - style: dot-matrix style parameters.
    /// - Returns: a rendered image, or `nil` if the symbol can't be created.
    public static func image(
        systemName: String,
        pointSize: CGFloat = 17,
        weight: UIImage.SymbolWeight = .semibold,
        tint: UIColor? = nil,
        traits: UITraitCollection? = nil,
        style: DotMatrixIconStyle = .standard
    ) -> UIImage? {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let symbol = UIImage(systemName: systemName, withConfiguration: config) else {
            return nil
        }
        let key = CacheKey(
            source: .symbol(name: systemName, pointSize: pointSize, weight: weight.rawValue),
            tint: tint, traits: traits, style: style)
        return cached(key: key) {
            render(source: symbol, tint: tint, traits: traits, style: style)
        }
    }

    /// Build a dot-matrix image from an arbitrary source image (treated as a glyph
    /// via its alpha channel). Useful for programmatic glyphs.
    ///
    /// - Parameter cacheID: a stable identity for `source` so the result can be
    ///   cached; pass `nil` to skip caching (the render still happens).
    public static func image(
        source: UIImage,
        cacheID: String?,
        tint: UIColor? = nil,
        traits: UITraitCollection? = nil,
        style: DotMatrixIconStyle = .standard
    ) -> UIImage {
        guard let cacheID else {
            return render(source: source, tint: tint, traits: traits, style: style) ?? source
        }
        let key = CacheKey(
            source: .custom(id: cacheID, size: source.size),
            tint: tint, traits: traits, style: style)
        return cached(key: key) {
            render(source: source, tint: tint, traits: traits, style: style)
        } ?? source
    }

    /// Clear the render cache (e.g. on a memory warning).
    public static func clearCache() {
        cache.removeAllObjects()
    }

    // MARK: Rendering

    private static func render(
        source: UIImage,
        tint: UIColor?,
        traits: UITraitCollection?,
        style: DotMatrixIconStyle
    ) -> UIImage? {
        let scale = UIScreen.main.scale
        let size = source.size
        guard size.width > 0, size.height > 0 else { return nil }

        // 1. Rasterize the glyph's alpha into a single-channel coverage buffer at
        //    device scale, so we sample real pixels.
        guard let coverage = AlphaBuffer(image: source, scale: scale) else { return nil }

        // 2. Pick a dot cell pitch (in points) from the glyph's longer side so the
        //    grid keeps ~targetDotsAcross cells, clamped to the legible range.
        let longerSide = max(size.width, size.height)
        let rawCell = longerSide / max(style.targetDotsAcross, 1)
        let cellPoints = min(max(rawCell, style.minCellPoints), style.maxCellPoints)
        let cols = max(1, Int((size.width / cellPoints).rounded()))
        let rows = max(1, Int((size.height / cellPoints).rounded()))
        let cellW = size.width / CGFloat(cols)
        let cellH = size.height / CGFloat(rows)

        let resolvedTint: UIColor? = {
            guard let tint else { return nil }
            if let traits { return tint.resolvedColor(with: traits) }
            return tint
        }()

        // 3. Draw a rounded-square dot per covered cell, sized by coverage.
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let dotImage = renderer.image { ctx in
            let cg = ctx.cgContext
            (resolvedTint ?? .black).setFill()
            for row in 0..<rows {
                for col in 0..<cols {
                    let cellRect = CGRect(
                        x: CGFloat(col) * cellW, y: CGFloat(row) * cellH,
                        width: cellW, height: cellH)
                    let cov = coverage.coverage(in: cellRect, imageSize: size)
                    guard cov >= style.coverageFloor else { continue }
                    // Available square inside the cell after spacing.
                    let cellMin = min(cellW, cellH)
                    let avail = cellMin * (1 - style.spacingFraction)
                    let scaleForCov = style.minDotScale + (1 - style.minDotScale) * min(cov, 1)
                    let dotSide = avail * scaleForCov
                    let dotRect = CGRect(
                        x: cellRect.midX - dotSide / 2,
                        y: cellRect.midY - dotSide / 2,
                        width: dotSide, height: dotSide)
                    let radius = dotSide * style.cornerRadiusFraction
                    cg.addPath(UIBezierPath(roundedRect: dotRect, cornerRadius: radius).cgPath)
                }
            }
            cg.fillPath()
        }

        return dotImage.withRenderingMode(resolvedTint == nil ? .alwaysTemplate : .alwaysOriginal)
    }

    // MARK: Cache

    private static let cache = NSCache<NSString, UIImage>()

    private static func cached(key: CacheKey, _ make: () -> UIImage?) -> UIImage? {
        let k = key.string as NSString
        if let hit = cache.object(forKey: k) { return hit }
        guard let made = make() else { return nil }
        cache.setObject(made, forKey: k)
        return made
    }

    private struct CacheKey {
        enum Source {
            case symbol(name: String, pointSize: CGFloat, weight: Int)
            case custom(id: String, size: CGSize)
        }
        let source: Source
        let tint: UIColor?
        let traits: UITraitCollection?
        let style: DotMatrixIconStyle

        var string: String {
            var parts: [String] = []
            switch source {
            case let .symbol(name, pointSize, weight):
                parts.append("sym:\(name):\(pointSize):\(weight)")
            case let .custom(id, size):
                parts.append("cus:\(id):\(size.width)x\(size.height)")
            }
            if let tint {
                let resolved = traits.map { tint.resolvedColor(with: $0) } ?? tint
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
                parts.append("tint:\(r),\(g),\(b),\(a)")
            } else {
                parts.append("tint:template")
            }
            parts.append("scale:\(UIScreen.main.scale)")
            parts.append("style:\(style.cornerRadiusFraction),\(style.spacingFraction),\(style.targetDotsAcross),\(style.minCellPoints),\(style.maxCellPoints),\(style.coverageFloor),\(style.minDotScale)")
            return parts.joined(separator: "|")
        }
    }
}

// MARK: - Alpha coverage buffer

/// A device-scale alpha-only rasterization of an image, with a box-filter coverage
/// query over an arbitrary (point-space) rect. Used to measure how much of each dot
/// cell the glyph covers.
private struct AlphaBuffer {
    let pixels: [UInt8]
    let width: Int
    let height: Int
    let scale: CGFloat

    init?(image: UIImage, scale: CGFloat) {
        let w = max(1, Int((image.size.width * scale).rounded()))
        let h = max(1, Int((image.size.height * scale).rounded()))
        guard let cgBase = image.cgImage ?? AlphaBuffer.rasterize(image, scale: scale) else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: w * h)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = buffer.withUnsafeMutableBytes({ raw -> CGContext? in
            guard let base = raw.baseAddress else { return nil }
            return CGContext(
                data: base, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
        }) else { return nil }
        context.draw(cgBase, in: CGRect(x: 0, y: 0, width: w, height: h))
        self.pixels = buffer
        self.width = w
        self.height = h
        self.scale = scale
    }

    /// Render a (possibly vector / symbol) image into a CGImage so we have pixels.
    private static func rasterize(_ image: UIImage, scale: CGFloat) -> CGImage? {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let drawn = renderer.image { _ in
            image.withRenderingMode(.alwaysOriginal).draw(in: CGRect(origin: .zero, size: image.size))
        }
        return drawn.cgImage
    }

    /// Mean alpha coverage (0…1) of the pixels under `rect` (given in image point
    /// space). The rect is mapped to pixel space via `scale`.
    func coverage(in rect: CGRect, imageSize: CGSize) -> CGFloat {
        let px0 = max(0, Int((rect.minX * scale).rounded(.down)))
        let py0 = max(0, Int((rect.minY * scale).rounded(.down)))
        let px1 = min(width, Int((rect.maxX * scale).rounded(.up)))
        let py1 = min(height, Int((rect.maxY * scale).rounded(.up)))
        guard px1 > px0, py1 > py0 else { return 0 }
        var sum = 0
        for y in py0..<py1 {
            let rowBase = y * width
            for x in px0..<px1 {
                sum += Int(pixels[rowBase + x])
            }
        }
        let count = (px1 - px0) * (py1 - py0)
        return count > 0 ? CGFloat(sum) / CGFloat(count) / 255.0 : 0
    }
}

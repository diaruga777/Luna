//
//  EclipseCorona.swift
//  LunaDesignSystem
//

import UIKit

/// The shared corona renderer for every eclipse transition in the app.
///
/// Modelled on what a camera actually records at totality rather than on a soft
/// glow:
///
/// * **Chromosphere.** A hairline of near-white, very slightly warm light sitting
///   directly on the limb. This is the single strongest "real photograph" cue —
///   a Gaussian halo has no hard inner edge, a real corona does.
/// * **Power-law falloff.** Coronal brightness drops roughly as an inverse power
///   of the distance from the limb, so it is bright and tight at the edge yet
///   still faintly present two radii out. A blur has a Gaussian profile, which
///   dies far too abruptly and reads as a lamp behind a card. The halo here is
///   built from concentric offset curves weighted by `(1 + d/d₀)^-n`.
/// * **Streamers.** The corona is not radially uniform: unevenly spaced
///   equatorial streamers reach far out, while the poles show only short fine
///   brushes. The angular unevenness is what stops the effect reading as a
///   rounded-rect drop shadow.
/// * **Pearl, not white.** Warm-white near the limb, cooling to a faint blue in
///   the outer streamers, with a whisper of the app's own tint mixed in.
/// Everything is baked into a cached `UIImage` per geometry: the drawing is
/// hundreds of stroked offset curves plus a gradient per streamer, far too much
/// to run inside a `draw(_:)` on every frame. Card geometry is constant within a
/// session, so only the first transition pays for the render. Images are
/// rasterised below screen scale on purpose — a corona is a smooth object, the
/// interpolation is invisible, and it keeps the one-off cost off the transition's
/// first frame.
public enum EclipseCorona {

    /// How far the corona reaches past the limb, in points.
    public static func reach(for size: CGSize) -> CGFloat {
        let shortest = min(size.width, size.height)
        return min(150, max(56, shortest * 0.42))
    }

    // MARK: - Colours

    /// Warm white: the inner corona and chromosphere, where the light is densest.
    private static let inner = UIColor(red: 1.00, green: 0.982, blue: 0.945, alpha: 1)
    /// Cool pearl: the outer streamers, which photograph distinctly bluer.
    private static let outer = UIColor(red: 0.878, green: 0.910, blue: 1.00, alpha: 1)
    /// The outer corona carries a whisper of the app's identity so each app's
    /// eclipse is subtly its own. The central Luna app's tint is white, so its
    /// corona stays pure pearl.
    private static func outerColor(tint: UIColor) -> UIColor {
        LunaSurfacePalette.blended(outer, toward: tint, amount: 0.22)
    }

    // MARK: - Streamers

    /// One coronal streamer: a wedge of light reaching out from the limb.
    private struct Streamer {
        let angle: CGFloat
        let halfWidth: CGFloat
        /// Fraction of the available reach this streamer extends to.
        let extent: CGFloat
        let intensity: CGFloat
    }

    /// A fixed streamer set. Deterministic so the corona is identical every time
    /// it appears — an eclipse that reshuffles between transitions reads as noise.
    private static let streamers: [Streamer] = {
        var seed: UInt32 = 0x45434C50  // "ECLP"
        func random() -> CGFloat {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return CGFloat(seed >> 8) / CGFloat(UInt32.max >> 8)
        }
        let count = 26
        return (0..<count).map { index in
            // Uneven angular spacing: evenly divided, then jittered by most of a
            // slot so no two gaps match.
            let slot = (CGFloat(index) + 0.5) / CGFloat(count)
            let angle = (slot + (random() - 0.5) * 0.8 / CGFloat(count)) * 2 * .pi
            // Equatorial (near-horizontal) streamers run long; polar ones are the
            // short fine brushes over the sun's poles.
            let equatorial = pow(abs(cos(angle)), 1.4)
            let extent = 0.28 + equatorial * 0.72 * (0.55 + random() * 0.45)
            return Streamer(
                angle: angle,
                // Narrow: real rays are fine structure, not petals.
                halfWidth: (0.010 + random() * 0.030) * 2 * .pi,
                extent: extent,
                intensity: 0.30 + random() * 0.70)
        }
    }()

    /// A fixed noise table, used to break up the regularity of the ray fan.
    private static let noise: [CGFloat] = {
        var seed: UInt32 = 0x52415953  // "RAYS"
        return (0..<64).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return CGFloat(seed >> 8) / CGFloat(UInt32.max >> 8)
        }
    }()

    // MARK: - Exterior corona (light falling outward from a rounded silhouette)

    // Cache reads/writes happen on the main thread only. `prewarm` renders on a
    // background queue but hops back here to store.
    @MainActor private static var exteriorCache: [String: UIImage] = [:]
    /// Geometries a `prewarm` is currently rendering, so a second call is a no-op.
    @MainActor private static var prewarming: Set<String> = []

    private static func exteriorKey(
        silhouetteSize: CGSize, cornerRadius: CGFloat, tint: UIColor,
        reach: CGFloat, scale: CGFloat
    ) -> String {
        cacheKey(
            "ext", silhouetteSize.width, silhouetteSize.height, cornerRadius,
            reach, scale, tint: tint)
    }

    /// Rasterisation scale for a corona that is only ever composited live, at
    /// the size it was rendered for: the in-app eclipse transition. Below screen
    /// scale on purpose — see `renderExterior`.
    public static let transitionScale: CGFloat = 1

    /// Rasterisation scale for a corona that is **magnified**: baked into launch
    /// artwork that a launch screen then scales to the device, or standing on
    /// the first-run card for as long as onboarding goes unanswered. At 1x the
    /// upscale is what it looks like — blocky streamer wedges and stepped halo
    /// banding, both plainly visible in the recorded splash.
    public static let artworkScale: CGFloat = 3

    /// The corona around an opaque rounded-rect silhouette, as an image whose
    /// bounds are `silhouetteSize` grown by `reach` on all sides. The silhouette
    /// interior is left untouched, so the image is safe to composite above or
    /// below the body it surrounds.
    ///
    /// A cache miss renders synchronously, which is a visible hitch on the frame
    /// that asks — call `prewarm(bodySize:cornerRadius:tint:)` as soon as the
    /// geometry is known so a transition never hits that path.
    ///
    /// `reach` overrides how far the light throws. The default suits a card;
    /// a body far smaller than one (a pill-sized button) wants a shorter throw
    /// than the 56pt floor, or its streamers dwarf the thing they surround.
    @MainActor
    public static func exteriorImage(
        silhouetteSize: CGSize,
        cornerRadius: CGFloat,
        tint: UIColor,
        reach: CGFloat? = nil,
        scale: CGFloat = transitionScale
    ) -> UIImage? {
        guard silhouetteSize.width > 1, silhouetteSize.height > 1 else { return nil }
        let throwDistance = reach ?? EclipseCorona.reach(for: silhouetteSize)
        let key = exteriorKey(
            silhouetteSize: silhouetteSize, cornerRadius: cornerRadius,
            tint: tint, reach: throwDistance, scale: scale)
        if let cached = exteriorCache[key] { return cached }
        let image = renderExterior(
            silhouetteSize: silhouetteSize, cornerRadius: cornerRadius,
            tint: tint, reach: throwDistance, scale: scale)
        if let image { exteriorCache[key] = image }
        return image
    }

    /// Renders and caches a geometry's corona on a background queue.
    ///
    /// The raster is hundreds of stroked offset curves plus a gradient per ray
    /// slice over a canvas larger than the card — tens of milliseconds, which is
    /// several dropped frames if it lands on the tap that starts the transition.
    /// Call this the moment the card geometry is known (the carousel does it from
    /// `viewDidLayoutSubviews`); by the first tap the image is already waiting.
    /// Idempotent, and cheap to call on every layout pass.
    @MainActor
    public static func prewarm(
        bodySize: CGSize, cornerRadius: CGFloat, tint: UIColor,
        reach: CGFloat? = nil,
        scale: CGFloat = transitionScale
    ) {
        guard bodySize.width > 1, bodySize.height > 1 else { return }
        let throwDistance = reach ?? EclipseCorona.reach(for: bodySize)
        let key = exteriorKey(
            silhouetteSize: bodySize, cornerRadius: cornerRadius, tint: tint,
            reach: throwDistance, scale: scale)
        guard exteriorCache[key] == nil, prewarming.insert(key).inserted else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let image = renderExterior(
                silhouetteSize: bodySize, cornerRadius: cornerRadius,
                tint: tint, reach: throwDistance, scale: scale)
            Task { @MainActor in
                prewarming.remove(key)
                if let image, exteriorCache[key] == nil { exteriorCache[key] = image }
            }
        }
    }

    /// The actual drawing. Deliberately free of UIKit state so `prewarm` can run
    /// it off the main thread: `UIGraphicsImageRenderer`'s block form keeps its
    /// context thread-local, and every colour here is static (never a dynamic
    /// `UIColor` needing trait resolution).
    private static func renderExterior(
        silhouetteSize: CGSize, cornerRadius: CGFloat, tint: UIColor,
        reach: CGFloat, scale: CGFloat
    ) -> UIImage? {
        let size = CGSize(
            width: silhouetteSize.width + reach * 2,
            height: silhouetteSize.height + reach * 2)
        let silhouette = CGRect(
            origin: CGPoint(x: reach, y: reach), size: silhouetteSize)

        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        // `transitionScale` (1x) for a corona composited at the size it was
        // rendered for. Core Graphics defers rasterisation to image creation, so
        // cost tracks pixel count almost exactly — 2x is 4x the work — and
        // everything in this pass is smooth and low-frequency, where displaying
        // 1:1 hides the coarseness. The one detail that needs real resolution
        // even then, the chromosphere hairline, is a vector layer in
        // `EclipseCoronaView` instead.
        //
        // A corona that will be MAGNIFIED is a different problem, and 1x was the
        // wrong answer for it: the launch artwork is baked at 3x from a 1x
        // corona, so its streamer wedges arrive as 3x3 blocks. Those callers
        // pass `artworkScale`.
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { rendererContext in
            let context = rendererContext.cgContext
            // Clip away the silhouette interior so nothing leaks over the body.
            let outside = UIBezierPath(rect: CGRect(origin: .zero, size: size))
            outside.append(
                UIBezierPath(roundedRect: silhouette, cornerRadius: cornerRadius))
            outside.usesEvenOddFillRule = true
            context.saveGState()
            context.addPath(outside.cgPath)
            context.clip(using: .evenOdd)
            context.setBlendMode(.screen)

            drawHalo(
                context: context, silhouette: silhouette,
                cornerRadius: cornerRadius, reach: reach, tint: tint, scale: scale)
            drawStreamers(
                context: context, silhouette: silhouette, reach: reach, tint: tint,
                scale: scale)
            context.restoreGState()
        }
    }

    /// The chromosphere: the hairline on the limb itself, as `(width, alpha)` pairs
    /// to stroke on the body's own outline. Drawn as vector layers rather than
    /// baked into the raster so it stays razor-sharp at any scale — the hard inner
    /// edge is the whole reason the corona reads as photographed. Only the outer
    /// half of each stroke shows; the opaque body covers the rest.
    static let chromosphereStrokes: [(width: CGFloat, alpha: CGFloat)] = [
        (5.0, 0.16), (2.0, 0.34), (0.9, 0.82),
    ]

    /// The chromosphere colour, resolved.
    static var chromosphereColor: UIColor { inner }

    /// The smooth part of the corona: concentric offset curves of the silhouette,
    /// weighted by a power law so the profile has a bright edge and a long tail.
    private static func drawHalo(
        context: CGContext, silhouette: CGRect,
        cornerRadius: CGFloat, reach: CGFloat, tint: UIColor, scale: CGFloat
    ) {
        let outerColor = outerColor(tint: tint)
        // One ring per rasterised pixel. The profile is a piecewise-constant
        // stack of rings, so at 1x-per-point it bands wherever the falloff is
        // steepest — right at the limb, and visibly so once magnified. Stepping
        // with the raster keeps every ring one pixel wide whatever the scale.
        let step: CGFloat = 1 / max(1, scale)
        var distance = step / 2
        context.setLineWidth(step * 1.7)
        while distance < reach {
            let progress = distance / reach
            // (1 + d/d₀)^-n — bright and tight at the limb, still faintly alive
            // at the far edge, unlike a blur's Gaussian shoulder.
            let falloff = pow(1 + distance / 6.5, -1.95)
            let color = LunaSurfacePalette.blended(
                inner, toward: outerColor, amount: min(1, progress * 1.6))
            context.setStrokeColor(
                color.withAlphaComponent(0.42 * falloff).cgColor)
            let path = UIBezierPath(
                roundedRect: silhouette.insetBy(dx: -distance, dy: -distance),
                cornerRadius: cornerRadius + distance)
            context.addPath(path.cgPath)
            context.strokePath()
            distance += step
        }
    }

    /// The angular structure.
    ///
    /// Each ray is fanned into thin slices whose brightness follows a raised
    /// cosine across the ray's width, so it fades out sideways instead of ending
    /// at a visible straight edge. Every slice runs its gradient from the
    /// silhouette's *center* out to that slice's own limb distance plus the ray
    /// length: starting at the center means the interior — which the caller's clip
    /// discards — absorbs the ramp-up, so the ray emerges exactly on the limb with
    /// no arc where the gradient began. (A single circular start radius across the
    /// whole ray is what produced visible arcs against a non-circular silhouette.)
    private static func drawStreamers(
        context: CGContext, silhouette: CGRect, reach: CGFloat, tint: UIColor,
        scale: CGFloat
    ) {
        let center = CGPoint(x: silhouette.midX, y: silhouette.midY)
        let outerColor = outerColor(tint: tint)
        // Slices with the raster, for the same reason the halo steps with it: a
        // fixed count leaves the raised cosine quantised into that many flat
        // wedges, and the wedge edges are the diagonal banding visible in
        // magnified artwork.
        let slices = Int(15 * max(1, scale))
        for (rayIndex, streamer) in streamers.enumerated() {
            let length = reach * streamer.extent
            guard length > 2 else { continue }
            let sliceWidth = streamer.halfWidth * 2 / CGFloat(slices)

            for slice in 0..<slices {
                let offset = (CGFloat(slice) + 0.5) / CGFloat(slices) * 2 - 1  // -1…1
                // Raised cosine: full strength on the ray's axis, zero at its edges.
                let weight = pow(cos(offset * .pi / 2), 2)
                guard weight > 0.01 else { continue }
                let angle = streamer.angle + offset * streamer.halfWidth
                let limb = limbDistance(from: silhouette, angle: angle)
                // Ragged tips: without per-slice jitter every ray ends on a clean
                // arc and the set reads as a rendered starburst.
                let jitter = 0.86 + noise[(rayIndex * slices + slice) % noise.count] * 0.28
                let end = limb + length * jitter
                let atLimb = limb / end
                let peak = 0.30 * streamer.intensity * weight

                guard let gradient = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [
                        inner.withAlphaComponent(peak).cgColor,
                        inner.withAlphaComponent(peak).cgColor,
                        outerColor.withAlphaComponent(peak * 0.45).cgColor,
                        outerColor.withAlphaComponent(peak * 0.12).cgColor,
                        outerColor.withAlphaComponent(0).cgColor,
                    ] as CFArray,
                    locations: [
                        0,
                        atLimb,
                        atLimb + (1 - atLimb) * 0.28,
                        atLimb + (1 - atLimb) * 0.62,
                        1,
                    ])
                else { continue }

                context.saveGState()
                context.addPath(
                    wedge(
                        center: center, angle: angle,
                        // Exactly abutting. Overlapping slices would screen-blend
                        // into bright seams down the middle of every ray.
                        halfWidth: sliceWidth * 0.5, radius: end))
                context.clip()
                context.drawRadialGradient(
                    gradient,
                    startCenter: center, startRadius: 0,
                    endCenter: center, endRadius: end,
                    options: [])
                context.restoreGState()
            }
        }
    }

    // MARK: - Interior corona (light falling inward from the frame edges)

    @MainActor private static var interiorCache: [String: UIImage] = [:]

    /// The corona for a source that already fills the transition container: the
    /// light has nowhere outward to go, so it falls inward from every edge. Same
    /// profile and structure as the exterior corona, mirrored.
    @MainActor
    public static func interiorImage(
        size: CGSize, cornerRadius: CGFloat, tint: UIColor
    ) -> UIImage? {
        guard size.width > 1, size.height > 1 else { return nil }
        let depth = min(72, min(size.width, size.height) * 0.16)
        let key = cacheKey(
            "int", size.width, size.height, cornerRadius, depth, tint: tint)
        if let cached = interiorCache[key] { return cached }

        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1.5
        let image = UIGraphicsImageRenderer(size: size, format: format).image { rendererContext in
            let context = rendererContext.cgContext
            context.setBlendMode(.screen)
            let bounds = CGRect(origin: .zero, size: size)
            let outerColor = outerColor(tint: tint)

            // One gradient band per edge, each clipped to the trapezoid of points
            // nearer that edge than any other. Brightness is a function of the
            // distance to the nearest edge, and the two bands agree exactly along
            // every diagonal, so the field is continuous and no seam shows.
            //
            // (Nested rounded-rect strokes, the obvious alternative, offset by √2
            // more at the corners than along the edges — which is what made this
            // read as a bevelled picture frame rather than light falling inward.)
            if let gradient = edgeGradient(depth: depth, outerColor: outerColor) {
                let corners = [
                    CGPoint(x: 0, y: 0),
                    CGPoint(x: size.width, y: 0),
                    CGPoint(x: size.width, y: size.height),
                    CGPoint(x: 0, y: size.height),
                ]
                let inset = bounds.insetBy(dx: depth, dy: depth)
                let innerCorners = [
                    CGPoint(x: inset.minX, y: inset.minY),
                    CGPoint(x: inset.maxX, y: inset.minY),
                    CGPoint(x: inset.maxX, y: inset.maxY),
                    CGPoint(x: inset.minX, y: inset.maxY),
                ]
                for edge in 0..<4 {
                    let next = (edge + 1) % 4
                    let trapezoid = CGMutablePath()
                    trapezoid.addLines(between: [
                        corners[edge], corners[next],
                        innerCorners[next], innerCorners[edge],
                    ])
                    trapezoid.closeSubpath()
                    // Straight in along this edge's inward normal.
                    let start = midpoint(corners[edge], corners[next])
                    let end = midpoint(innerCorners[edge], innerCorners[next])
                    context.saveGState()
                    context.addPath(trapezoid)
                    context.clip()
                    context.drawLinearGradient(
                        gradient, start: start, end: end, options: [])
                    context.restoreGState()
                }
            }

            // The hairline on the limb, inset just enough to stay inside bounds.
            for (width, alpha) in [(CGFloat(4.0), CGFloat(0.18)), (1.6, 0.40), (0.8, 0.80)] {
                context.setLineWidth(width)
                context.setStrokeColor(inner.withAlphaComponent(alpha).cgColor)
                context.addPath(
                    UIBezierPath(
                        roundedRect: bounds.insetBy(dx: width / 2, dy: width / 2),
                        cornerRadius: max(0, cornerRadius - width / 2)).cgPath)
                context.strokePath()
            }
        }
        interiorCache[key] = image
        return image
    }

    /// The interior falloff, sampled from the same power law the exterior halo
    /// strokes follow.
    private static func edgeGradient(depth: CGFloat, outerColor: UIColor) -> CGGradient? {
        let samples = 14
        var colors: [CGColor] = []
        var locations: [CGFloat] = []
        for sample in 0..<samples {
            let progress = CGFloat(sample) / CGFloat(samples - 1)
            let distance = progress * depth
            let falloff = pow(1 + distance / 6.5, -1.95)
            let color = LunaSurfacePalette.blended(
                inner, toward: outerColor, amount: min(1, progress * 1.6))
            colors.append(color.withAlphaComponent(0.62 * falloff).cgColor)
            locations.append(progress)
        }
        return CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: locations)
    }

    // MARK: - Geometry

    private static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    /// Distance from the silhouette's center to its edge along `angle`. The
    /// corner rounding is ignored — the small overshoot it causes falls under the
    /// clip or under the opaque body in every call site.
    private static func limbDistance(from rect: CGRect, angle: CGFloat) -> CGFloat {
        let dx = abs(cos(angle))
        let dy = abs(sin(angle))
        let horizontal = dx > 0.0001 ? (rect.width / 2) / dx : .greatestFiniteMagnitude
        let vertical = dy > 0.0001 ? (rect.height / 2) / dy : .greatestFiniteMagnitude
        return min(horizontal, vertical)
    }

    /// A pie wedge from `center`, approximated finely enough that its arc reads
    /// as smooth at the radii coronas use.
    private static func wedge(
        center: CGPoint, angle: CGFloat, halfWidth: CGFloat, radius: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        path.move(to: center)
        let segments = 10
        for step in 0...segments {
            let theta = angle - halfWidth
                + (halfWidth * 2) * CGFloat(step) / CGFloat(segments)
            path.addLine(
                to: CGPoint(
                    x: center.x + cos(theta) * radius,
                    y: center.y + sin(theta) * radius))
        }
        path.closeSubpath()
        return path
    }

    private static func cacheKey(
        _ kind: String, _ values: CGFloat..., tint: UIColor
    ) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        tint.getRed(&r, green: &g, blue: &b, alpha: &a)
        let numbers = values.map { String(format: "%.1f", $0) }.joined(separator: "x")
        return "\(kind)-\(numbers)-\(Int(r * 255)),\(Int(g * 255)),\(Int(b * 255))"
    }
}

/// A view that surrounds an opaque rounded-rect body with `EclipseCorona`'s
/// exterior corona. Its own bounds match the body; the corona lives in a child
/// that overhangs on every side, so callers position and animate it exactly as
/// they would the body itself.
public final class EclipseCoronaView: UIView {
    private let halo = UIImageView()
    private let cornerRadius: CGFloat
    /// The chromosphere hairline. Vector layers, not part of the raster, so the
    /// limb stays razor-sharp while the smooth passes rasterise cheaply at 1x.
    private var chromosphere: [CAShapeLayer] = []

    /// - Parameters:
    ///   - light: Recolours the whole corona to a single hue instead of the
    ///     photographic pearl. The pearl is the right answer over Luna's black
    ///     sky and invisible over a white one, so a surface that borrows the
    ///     corona for a light-mode replica passes the colour it needs here.
    ///     The falloff, streamers and chromosphere are unchanged — only the
    ///     colour is, taken from the render's own alpha.
    ///   - reach: How far the light throws past the limb, overriding the
    ///     card-sized default.
    ///   - scale: Rasterisation scale for the smooth passes. The default suits a
    ///     corona composited at the size it was rendered for; artwork that will
    ///     be scaled afterwards passes `EclipseCorona.artworkScale`.
    public init(
        bodySize: CGSize,
        cornerRadius: CGFloat,
        tint: UIColor,
        light: UIColor? = nil,
        reach: CGFloat? = nil,
        scale: CGFloat = EclipseCorona.transitionScale
    ) {
        self.cornerRadius = cornerRadius
        super.init(frame: CGRect(origin: .zero, size: bodySize))
        isUserInteractionEnabled = false
        clipsToBounds = false
        backgroundColor = .clear

        let reach = reach ?? EclipseCorona.reach(for: bodySize)
        halo.frame = bounds.insetBy(dx: -reach, dy: -reach)
        // Fixed (negative) margins with a flexible core: the overhang stays put
        // when the body resizes.
        halo.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        halo.contentMode = .scaleToFill
        let image = EclipseCorona.exteriorImage(
            silhouetteSize: bodySize, cornerRadius: cornerRadius, tint: tint,
            reach: reach, scale: scale)
        if let light {
            halo.image = image?.withRenderingMode(.alwaysTemplate)
            halo.tintColor = light
        } else {
            halo.image = image
        }
        addSubview(halo)

        // Only the outer half of each stroke is ever visible: every call site
        // composites this view beneath an opaque body.
        for stroke in EclipseCorona.chromosphereStrokes {
            let rim = CAShapeLayer()
            rim.fillColor = nil
            rim.strokeColor = (light ?? EclipseCorona.chromosphereColor)
                .withAlphaComponent(stroke.alpha).cgColor
            rim.lineWidth = stroke.width
            layer.addSublayer(rim)
            chromosphere.append(rim)
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let path = UIBezierPath(roundedRect: bounds, cornerRadius: cornerRadius).cgPath
        for rim in chromosphere {
            rim.frame = bounds
            rim.path = path
        }
    }
}

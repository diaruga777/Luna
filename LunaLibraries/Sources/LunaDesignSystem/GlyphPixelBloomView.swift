//
//  GlyphPixelBloomView.swift
//  LunaDesignSystem
//

import UIKit

/// The raster glyph-light renderer used by Luna's eclipse text reveals.
///
/// Both the onboarding headline and the shared loading-status label drive this
/// exact renderer, so their white-hot edge, cooling falloff, and additive halos
/// cannot drift apart.
///
/// The emitter is rebuilt at display cadence by intersecting the moving circle's
/// narrow trailing bands with a native-scale raster of the glyphs. Quartz shadows
/// are applied to that exact alpha image in additive passes, with the padded result
/// kept in its own view so light around the letters is not clipped to the text.
/// Frames are composited off the main thread; the display link only samples the
/// front's presentation transform and requests the current ready-made frame.
/// The general raster overload also lets onboarding image content ride the same
/// light pass.
public final class GlyphPixelBloomView: UIView {
    struct EdgeBand {
        let inner: CGFloat
        let outer: CGFloat
        let alpha: CGFloat
    }

    struct HaloPass {
        let radius: CGFloat
        let alpha: CGFloat
    }

    /// Which arc of the circle is the working front, and so which side of it
    /// the emitting bands trail on.
    public enum Edge { case topArc, bottomArc }

    public static let renderPadding: CGFloat = 42

    /// The intro line's edge speed (its travel over its reveal duration).
    /// Faster sweeps scale the falloff distances up by speed/reference so a
    /// glyph's brighten-and-cool takes the same TIME at any front speed.
    public static let referenceFrontSpeed: CGFloat = 46

    /// Where a frame is composited, off the main thread.
    ///
    /// Concurrent, and deliberately without a pool of its own: a view never has
    /// more than one frame in flight, so the tasks in the queue are at most one
    /// per blooming view, none of them ever blocks, and the parallelism settles
    /// wherever the cores put it. The mock Safari page's wave — a dozen elements
    /// lit in one pass — renders as fast as the machine allows.
    private static let renderQueue = DispatchQueue(
        label: "app.luna.onboarding.glyph-bloom",
        qos: .userInitiated,
        attributes: .concurrent)

    fileprivate static let edgeFalloff = [
        EdgeBand(inner: 0, outer: 1.75, alpha: 1.00),
        EdgeBand(inner: 1.75, outer: 4.00, alpha: 0.72),
        EdgeBand(inner: 4.00, outer: 7.25, alpha: 0.32),
        EdgeBand(inner: 7.25, outer: 10.50, alpha: 0.09),
    ]

    // Several optically additive passes are intentional. A single CALayer
    // shadow reads as soft text; stacked scales produce a clipped white core,
    // a dense local flare that erases legibility, and a broad low-frequency
    // wash like the first visible edge of the sun.
    fileprivate static let haloPasses = [
        HaloPass(radius: 30, alpha: 0.72),
        HaloPass(radius: 30, alpha: 0.72),
        HaloPass(radius: 18, alpha: 0.90),
        HaloPass(radius: 18, alpha: 0.90),
        HaloPass(radius: 10, alpha: 1.00),
        HaloPass(radius: 10, alpha: 1.00),
        HaloPass(radius: 5, alpha: 1.00),
        HaloPass(radius: 2, alpha: 1.00),
    ]

    /// The light's own layer, handed finished frames rather than drawing them.
    private let lightLayer = CALayer()

    private var glyphImage: UIImage?
    private var glyphFrame = CGRect.zero
    private var initialCircleFrame = CGRect.zero
    private var circleTravel: CGFloat = 0
    private var progress: CGFloat = 0
    private var revealStartTime: CFTimeInterval = 0
    private var revealDuration: CFTimeInterval = 0
    private var displayLink: CADisplayLink?
    /// Everything one pass's frames need, fixed when the pass begins. Nil until
    /// a raster has been configured; replaced, never mutated, so the render
    /// queue only ever reads a finished object.
    private var pass: Pass?
    /// Set while a frame is being composited. The display link does not queue a
    /// second one behind it: the tick after this one carries fresher geometry
    /// than a backlog would.
    private var isRenderingFrame = false
    /// Bumped whenever a pass is replaced, so a frame still in flight from the
    /// previous one is discarded instead of appearing over the new pass.
    private var passGeneration = 0
    private var edgeSagitta: CGFloat = 0
    private var edge = Edge.topArc
    private var edgeBandScale: CGFloat = 1
    private var rasterScale: CGFloat = 1
    private var offsetProvider: (() -> CGFloat?)?
    private var didSampleOffset = false
    /// Per-pass alpha for the additive passes. Thin glyph strokes want the
    /// full 1 — their saturation to a white core is the intro's look. A
    /// dense raster (a photograph) saturates even its mid-tones under eight
    /// additive passes and reads as a white slab; its owner lowers the gain
    /// so only genuinely bright pixels reach white heat. Gains above 1
    /// amplify instead: the falloff bands and outer halos are pushed toward
    /// full strength (each pass still clamps at 1), widening and whitening
    /// the light without touching its geometry.
    private var emitterGain: CGFloat = 1

    #if DEBUG
    public var glyphRasterForTesting: UIImage? { glyphImage }
    #endif

    public var usesRasterizedGlyphPixels: Bool {
        glyphImage != nil && !glyphFrame.isEmpty
    }

    public var usesStackedAdditiveHalos: Bool {
        Self.haloPasses.count >= 3
            && Self.haloPasses.first?.radius == 30
            && Self.haloPasses.last?.radius == 2
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        lightLayer.isOpaque = false
        // The composite arrives sized to its own rect; nothing here is ever
        // stretched, and an implicit fade between frames would smear the light.
        lightLayer.contentsGravity = .resize
        lightLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer.addSublayer(lightLayer)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    deinit {
        displayLink?.invalidate()
    }

    public func configure(
        glyphLabel: UILabel,
        glyphFrame: CGRect,
        circleFrame: CGRect,
        scale: CGFloat
    ) {
        let glyphFormat = UIGraphicsImageRendererFormat()
        glyphFormat.scale = scale
        glyphFormat.opaque = false
        let glyphRenderer = UIGraphicsImageRenderer(
            size: glyphLabel.bounds.size,
            format: glyphFormat)
        configure(
            raster: glyphRenderer.image { context in
                // UILabel resolves its text rect (including vertical alignment
                // and line layout) when drawing its layer. Calling drawText in
                // the full bounds bypasses that and offsets the emitting glyphs.
                glyphLabel.layer.render(in: context.cgContext)
            },
            rasterFrame: glyphFrame,
            circleFrame: circleFrame,
            scale: scale)
    }

    /// The general emitter form: any raster works as the light source — the
    /// additive passes brighten wherever it has luminance, so an image's
    /// bright pixels flare exactly the way glyph alpha does.
    public func configure(
        raster: UIImage,
        rasterFrame: CGRect,
        circleFrame: CGRect,
        scale: CGFloat
    ) {
        glyphImage = raster
        glyphFrame = rasterFrame
        initialCircleFrame = circleFrame
        rasterScale = scale
        progress = 0

        let radius = circleFrame.width / 2
        let halfWidth = bounds.width / 2
        edgeSagitta = radius - sqrt(max(radius * radius - halfWidth * halfWidth, 0))
        // A raster placed but not yet swept has no light of its own; whatever an
        // earlier pass left on the layer is not this one's.
        clearLight()
    }

    /// `offsetProvider` slaves the light to the occluder itself: it returns
    /// the moon layer's current *presentation* translation, so the emitting
    /// band sits exactly on the rendered edge no matter how the clocks
    /// drift — light lagging its own mask is what read as "the text appears,
    /// then brightens in chunks". Without a provider the band falls back to
    /// wall-clock progress anchored at the first display-link tick.
    public func reveal(
        circleTravel: CGFloat,
        duration: CFTimeInterval,
        edge: Edge? = nil,
        edgeBandScale: CGFloat = 1,
        emitterGain: CGFloat = 1,
        offsetProvider: (() -> CGFloat?)? = nil
    ) {
        stop()
        self.circleTravel = circleTravel
        // A sweep that uncovers works its leading arc: the top one going down,
        // the bottom one coming up. Only a conceal names its edge outright.
        self.edge = edge ?? (circleTravel < 0 ? .bottomArc : .topArc)
        self.edgeBandScale = max(edgeBandScale, 1)
        self.emitterGain = min(max(emitterGain, 0.05), 2)
        self.offsetProvider = offsetProvider
        didSampleOffset = false
        revealDuration = max(duration, 0.001)
        // Anchored by the first display-link tick, not by this call: when a
        // heavy transaction separates the call from the first rendered frame,
        // a wall-clock anchor would start the light already cooled.
        revealStartTime = 0
        progress = 0

        // Only a strip around the circle's leading edge ever emits light (the
        // bands hug the edge), so the per-frame render is a strip, not the
        // whole view. A view-height emitter made the display link collapse on
        // article-length text: whole lines never got their bright moment
        // because the frame rate fell to a handful of samples. The strip is
        // sized here because the falloff reach depends on the front's speed.
        pass = glyphImage?.cgImage.flatMap { raster in
            Pass(
                raster: raster,
                rasterFrame: glyphFrame,
                initialCircleFrame: initialCircleFrame,
                circleTravel: circleTravel,
                edge: self.edge,
                edgeSagitta: edgeSagitta,
                edgeBandScale: self.edgeBandScale,
                emitterGain: self.emitterGain,
                width: bounds.width,
                scale: rasterScale)
        }
        passGeneration += 1
        clearLight()

        let displayLink = CADisplayLink(
            target: self,
            selector: #selector(drawNextRevealFrame(_:)))
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: 30,
            maximum: 120,
            preferred: 60)
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    public func stop() {
        displayLink?.invalidate()
        displayLink = nil
        offsetProvider = nil
        // The pass owns two bitmaps, and the mock Safari page's wave has a dozen
        // passes alive at once. A frame still in flight holds its own reference,
        // so dropping this one only frees what nothing is drawing into.
        pass = nil
    }

    /// Drops whatever light is on screen. The layer keeps its last frame
    /// through `stop()` — a sweep that has run its course has taken the band
    /// off the view already — and is only emptied when a new pass is set up.
    private func clearLight() {
        lightLayer.contents = nil
    }

    @objc private func drawNextRevealFrame(_ link: CADisplayLink) {
        if revealStartTime == 0 { revealStartTime = link.timestamp }
        if let offsetProvider {
            if let offset = offsetProvider() {
                // Signed travel: an upward sweep translates negatively, and
                // the ratio of matching signs keeps progress in 0...1.
                let divisor = abs(circleTravel) >= 1
                    ? circleTravel
                    : (circleTravel < 0 ? -1 : 1)
                let sampled = min(max(offset / divisor, 0), 1)
                // An occluder added to the tree in the sweep's own turn has no
                // presentation state yet, so `presentation()` hands back the
                // MODEL layer — which the sweep has already moved to its
                // finished transform. Read as a real sample that would end the
                // light on its first tick, before a single pixel had emitted:
                // the conceal that reinstalls its occluder went out as a plain
                // top-down wipe. A FIRST sample of an already-finished sweep is
                // therefore "not committed yet", not "over".
                if didSampleOffset || sampled < 1 {
                    didSampleOffset = true
                    progress = sampled
                } else {
                    progress = 0
                }
            } else {
                // nil before the occluder's animation is committed, and again
                // after it is removed: not-yet-started vs finished.
                progress = didSampleOffset ? 1 : 0
            }
        } else {
            let elapsed = link.timestamp - revealStartTime
            progress = min(max(CGFloat(elapsed / revealDuration), 0), 1)
        }
        requestFrame(atProgress: progress)
        if progress >= 1 {
            stop()
        }
    }

    /// Composites one frame off the main thread and hands it to the layer.
    ///
    /// A tick that arrives while the previous frame is still being composited
    /// is dropped rather than queued: it is the CURRENT edge position the light
    /// has to sit on, and a backlog would deliver stale ones late.
    private func requestFrame(atProgress progress: CGFloat) {
        guard let pass, !isRenderingFrame else { return }
        isRenderingFrame = true
        let generation = passGeneration
        Self.renderQueue.async { [weak self] in
            let frame = pass.frame(atProgress: progress)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRenderingFrame = false
                guard let frame, generation == self.passGeneration else { return }
                self.show(frame)
            }
        }
    }

    private func show(_ frame: Pass.Frame) {
        lightLayer.contentsScale = rasterScale
        lightLayer.frame = frame.rect
        lightLayer.contents = frame.image
    }

    /// One pass's fixed drawing, and the frames it makes.
    ///
    /// Every value here is settled before the sweep starts, so a frame is a pure
    /// function of its progress and the render queue never reads mutable view
    /// state. The two bitmaps are built once and reused: at display cadence a
    /// fresh backing store per frame is pure allocation.
    ///
    /// **Core Graphics, not UIKit, and that is not a preference.** Off the main
    /// thread, `UIGraphicsImageRenderer` and `UIImage.draw(in:)` composite
    /// NOTHING — no error, no warning, an empty buffer every frame, with a light
    /// that never appears. So the emitter and the composite are `CGContext`s
    /// with the UIKit y-down flip applied by hand, and rasters are drawn as
    /// `CGImage`s: `draw(_:in:blendMode:alpha:)` below re-flips around each rect
    /// to match `UIImage.draw(in:)`'s convention.
    private final class Pass {
        struct Frame {
            let image: CGImage
            /// Where the composite belongs in the bloom view's coordinates.
            let rect: CGRect
        }

        private let raster: CGImage
        private let rasterFrame: CGRect
        private let initialCircleFrame: CGRect
        private let circleTravel: CGFloat
        private let edge: Edge
        private let edgeSagitta: CGFloat
        private let edgeBandScale: CGFloat
        private let emitterGain: CGFloat
        private let width: CGFloat
        private let scale: CGFloat
        private let stripHeight: CGFloat
        private let scaledFalloffReach: CGFloat
        /// How far past the strip the widest halo can still put light. A shadow's
        /// blur is in the USER SPACE it was set in — points here, as in the view
        /// context this drawing came from — so the reach is the widest radius
        /// itself, plus a little.
        private let glowReach: CGFloat
        /// The halo stack with its gain already folded in, so a frame does no
        /// colour arithmetic.
        private let halos: [(blur: CGFloat, color: CGColor)]
        private let drawAlpha: CGFloat
        /// The rect the emitter image is drawn back into. Deliberately the
        /// UNROUNDED strip size.
        private let emitterSize: CGSize
        private let compositeSize: CGSize
        private let emitterContext: CGContext
        private let compositeContext: CGContext
        /// Each bitmap's own size in points, which is a whole number of device
        /// pixels and so is not always its logical size. The flip is applied
        /// against THIS, so user-space (0, 0) is the bitmap's top-left corner,
        /// matching `UIGraphicsImageRenderer`'s convention.
        private let emitterBitmapSize: CGSize
        private let compositeBitmapSize: CGSize

        init?(
            raster: CGImage,
            rasterFrame: CGRect,
            initialCircleFrame: CGRect,
            circleTravel: CGFloat,
            edge: Edge,
            edgeSagitta: CGFloat,
            edgeBandScale: CGFloat,
            emitterGain: CGFloat,
            width: CGFloat,
            scale: CGFloat
        ) {
            self.raster = raster
            self.rasterFrame = rasterFrame
            self.initialCircleFrame = initialCircleFrame
            self.circleTravel = circleTravel
            self.edge = edge
            self.edgeSagitta = edgeSagitta
            self.edgeBandScale = edgeBandScale
            self.emitterGain = emitterGain
            self.width = width
            self.scale = max(scale, 1)
            let pixelScale = max(scale, 1)
            scaledFalloffReach = (GlyphPixelBloomView.edgeFalloff.last?.outer ?? 12)
                * edgeBandScale
            stripHeight = ((scaledFalloffReach + edgeSagitta + 12) * pixelScale)
                .rounded(.up) / pixelScale
            let widestHalo = GlyphPixelBloomView.haloPasses.map(\.radius).max() ?? 30
            glowReach = widestHalo + 4
            // The radii are in POINTS, as the view context they were tuned in
            // measured them, and a bitmap context measures a shadow's blur in
            // DEVICE PIXELS however its transform is scaled afterwards — so each
            // one is converted here. Skip this and the white cores still land
            // perfectly while every soft outer halo comes in at a third of its
            // reach: the broad low-frequency wash disappears and the light reads
            // as a hard glow instead of a sunrise.
            halos = GlyphPixelBloomView.haloPasses.map { halo in
                (halo.radius * pixelScale,
                 UIColor.white
                     .withAlphaComponent(min(halo.alpha * emitterGain, 1))
                     .cgColor)
            }
            drawAlpha = min(emitterGain, 1)
            emitterSize = CGSize(
                width: (width * pixelScale).rounded(.up) / pixelScale,
                height: stripHeight)
            // Whole device pixels, so the composite maps onto the bloom view's
            // own pixel grid one for one and Core Animation never resamples it.
            compositeSize = CGSize(
                width: ((width * pixelScale).rounded(.up) + 1) / pixelScale,
                height: (((stripHeight + glowReach * 2) * pixelScale).rounded(.up) + 1)
                    / pixelScale)
            // Both bitmaps work in points, like the view whose drawing this is.
            guard let emitter = Pass.makeBitmap(
                    pixelWidth: Int((emitterSize.width * pixelScale).rounded()),
                    pixelHeight: Int((emitterSize.height * pixelScale).rounded()),
                    unitsPerPixel: 1 / pixelScale),
                  let composite = Pass.makeBitmap(
                    pixelWidth: Int((compositeSize.width * pixelScale).rounded()),
                    pixelHeight: Int((compositeSize.height * pixelScale).rounded()),
                    unitsPerPixel: 1 / pixelScale)
            else { return nil }
            emitterContext = emitter.context
            emitterBitmapSize = emitter.size
            compositeContext = composite.context
            compositeBitmapSize = composite.size
        }

        /// A reusable bitmap in UIKit's coordinates — y down, origin at the
        /// top-left — whose user unit is `unitsPerPixel` of a device pixel.
        private static func makeBitmap(
            pixelWidth: Int,
            pixelHeight: Int,
            unitsPerPixel: CGFloat
        ) -> (context: CGContext, size: CGSize)? {
            guard pixelWidth > 0, pixelHeight > 0, unitsPerPixel > 0,
                  let context = CGContext(
                    data: nil,
                    width: pixelWidth,
                    height: pixelHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)
                        ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return nil }
            let size = CGSize(
                width: CGFloat(pixelWidth) * unitsPerPixel,
                height: CGFloat(pixelHeight) * unitsPerPixel)
            context.scaleBy(x: 1 / unitsPerPixel, y: 1 / unitsPerPixel)
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            return (context, size)
        }

        /// `UIImage.draw(in:blendMode:alpha:)`, in Core Graphics: a `CGImage`
        /// draws bottom-up, so it has to be flipped back around its own rect.
        private func draw(
            _ image: CGImage,
            in rect: CGRect,
            blendMode: CGBlendMode,
            alpha: CGFloat,
            into context: CGContext
        ) {
            context.saveGState()
            context.setBlendMode(blendMode)
            context.setAlpha(alpha)
            context.translateBy(x: 0, y: rect.midY)
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: 0, y: -rect.midY)
            context.draw(image, in: rect)
            context.restoreGState()
        }

        func frame(atProgress progress: CGFloat) -> Frame? {
            let strip = stripRect(atProgress: progress)
            let rect = compositeRect(for: strip)
            guard let emitter = emitterImage(atProgress: progress, strip: strip)
            else { return nil }

            let context = compositeContext
            context.saveGState()
            context.clear(CGRect(origin: .zero, size: compositeBitmapSize))
            context.translateBy(x: -rect.minX, y: -rect.minY)
            context.setBlendMode(.plusLighter)
            let emitterRect = CGRect(origin: strip.origin, size: emitterSize)
            for halo in halos {
                context.saveGState()
                context.setShadow(offset: .zero, blur: halo.blur, color: halo.color)
                draw(
                    emitter,
                    in: emitterRect,
                    blendMode: .plusLighter,
                    alpha: drawAlpha,
                    into: context)
                context.restoreGState()
            }
            context.restoreGState()
            guard let image = context.makeImage() else { return nil }
            return Frame(image: image, rect: rect)
        }

        private func stripRect(atProgress progress: CGFloat) -> CGRect {
            // The bands trail the moving edge: above a descending circle's top
            // arc, below a climbing (or concealing) one's bottom arc.
            let circle = initialCircleFrame.offsetBy(dx: 0, dy: circleTravel * progress)
            let y = edge == .bottomArc
                ? circle.maxY - edgeSagitta - 8
                : circle.minY - scaledFalloffReach - 4
            // The emitter is a bitmap too: snapping only the final composite
            // still resamples glyphs onto a different fractional grid on every
            // frame, making the white core wobble against the settled ink.
            return CGRect(
                x: 0, y: (y * scale).rounded(.down) / scale,
                width: width, height: stripHeight)
        }

        /// The strip plus everywhere its halos reach, snapped DOWN to a device
        /// pixel. Snapping the buffer rather than the light is the whole point:
        /// the strip keeps its exact subpixel position inside the buffer, so the
        /// glyphs land where they always landed, while the buffer's own grid
        /// lines up with the view's.
        private func compositeRect(for strip: CGRect) -> CGRect {
            let top = strip.minY - glowReach
            return CGRect(
                origin: CGPoint(x: 0, y: (top * scale).rounded(.down) / scale),
                size: compositeSize)
        }

        private func emitterImage(atProgress progress: CGFloat, strip: CGRect) -> CGImage? {
            let circleFrame = initialCircleFrame.offsetBy(
                dx: 0,
                dy: circleTravel * progress)
            let context = emitterContext
            context.saveGState()
            context.clear(CGRect(origin: .zero, size: emitterBitmapSize))
            context.translateBy(x: -strip.minX, y: -strip.minY)
            for band in GlyphPixelBloomView.edgeFalloff {
                context.saveGState()
                let ring = UIBezierPath(
                    ovalIn: circleFrame.insetBy(
                        dx: -band.outer * edgeBandScale,
                        dy: -band.outer * edgeBandScale))
                ring.append(UIBezierPath(
                    ovalIn: circleFrame.insetBy(
                        dx: -band.inner * edgeBandScale,
                        dy: -band.inner * edgeBandScale)))
                ring.usesEvenOddFillRule = true
                context.addPath(ring.cgPath)
                context.clip(using: .evenOdd)
                draw(
                    raster,
                    in: rasterFrame,
                    blendMode: .normal,
                    alpha: min(band.alpha * max(emitterGain, 1), 1),
                    into: context)
                context.restoreGState()
            }
            context.restoreGState()
            return context.makeImage()
        }
    }
}

//
//  StoneEffectView.swift
//  LunaContentRendering
//
//  A standalone UIKit component that applies a real-time "stone" effect to a view:
//  the captured content is diffused by a scattered glass blur, then tinted toward a
//  stone colour with a centre→edge coverage gradient (clear rim, coloured middle)
//  and a fuzzy tumbled speckle. Two materials — jellystone (pastel sea glass) and
//  luna (milky, cool). A tap fires an expanding ripple that sweeps the effect
//  in/out. Shares the capture/ripple/display-link machinery with the other effects.
//
//  Usage:
//      let effect = imageView.applyStone { c in
//          c.material = .jellystone
//          c.blurRadius = 12
//          c.tint = UIColor(red: 0.55, green: 0.85, blue: 0.78, alpha: 0.55)
//      }
//      effect.ripplesOnTap = true     // tap to ripple the effect on/off
//      effect.remove()                // or imageView.removeStone()
//
//  Each display-link tick the target layer tree is rendered into an IOSurface-
//  backed Metal texture via `CARenderer` (GPU, animation-accurate), then a single
//  fragment-shader pass produces the stone look. A CPU snapshot path is the
//  fallback if CARenderer is unavailable.
//

import UIKit
import Metal
import QuartzCore
import simd

// MARK: - Configuration

/// All tunable parameters of the effect. Assigning any property updates the
/// effect on the next frame. Safe to mutate from the main thread at any time.
public struct StoneConfig: Equatable {

    // -- material ------------------------------------------------------------

    /// The kind of stone the look emulates.
    public enum Material: Int, CaseIterable {
        case jellystone   // cheerful pastel sea glass
        case luna       // milky semi-transparent luna
        public var title: String {
            switch self {
            case .jellystone: return "Jellystone"
            case .luna: return "Luna"
            }
        }
    }

    public var material: Material = .jellystone

    // -- stone body ----------------------------------------------------------

    /// Radius, in points, of the frosted diffusion blur (the glass softness).
    public var blurRadius: CGFloat = 8

    /// 0...1 fuzzy tumbled speckle — the gritty frosting of beach glass.
    public var grain: CGFloat = 0.3

    /// Refraction strength, in points: how much the stone's uneven surface bends the
    /// image seen through it (0 = no bending, flat glass).
    public var distortion: CGFloat = 10

    /// 0...1 milkiness/haze of the material (how cloudy/opaque the stone is).
    public var translucency: CGFloat = 0.6

    /// Feature size, in points, of the procedural surface — small = fine pebbly
    /// facets, large = broad smooth undulations.
    public var surfaceScale: CGFloat = 50

    /// The stone's colour. Alpha is the tint strength (how strongly the material is
    /// recoloured / tinted).
    public var tint: UIColor = UIColor(red: 0.55, green: 0.85, blue: 0.78, alpha: 0.55)

    /// Saturation multiplier of the body. 1 = unchanged.
    public var saturation: CGFloat = 1.1

    /// Brightness multiplier of the body.
    public var brightness: CGFloat = 1.06

    /// Advanced: whether the captured source needs a vertical flip. Leave nil for
    /// automatic; set explicitly if the image looks upside-down.
    public var sourceFlippedOverride: Bool? = nil

    // -- ripple transition (animates the effect on/off from a tap point) -----

    /// Peak radial displacement, in points, of the glass at the wavefront.
    public var ripplePushDistance: CGFloat = 28

    /// Speed of the expanding wavefront, in points per second.
    public var rippleSpeed: CGFloat = 1400

    /// Half-thickness, in points, of the Gaussian push ring.
    public var rippleWidth: CGFloat = 70

    /// Softness, in points, of the reveal step at the wavefront.
    public var rippleEdge: CGFloat = 40

    /// Wavelength, in points, of the dispersive trailing ripples. 0 disables the
    /// oscillation and leaves a single clean ring.
    public var rippleWavelength: CGFloat = 80

    /// e-folding length, in points, over which the trailing ripples die out.
    public var rippleDecay: CGFloat = 140

    /// Total duration of the transition, in seconds. 0 auto-fits to the view.
    public var rippleDuration: TimeInterval = 0

    /// How the tap-ripple sweeps the effect in and out — the wavefront *shape*.
    public enum RevealMode: Int, CaseIterable {
        case radial, diamond, bars, dissolve, spiral, venetian
        public var title: String {
            switch self {
            case .radial: return "Radial"
            case .diamond: return "Diamond"
            case .bars: return "Bars"
            case .dissolve: return "Dissolve"
            case .spiral: return "Spiral"
            case .venetian: return "Venetian"
            }
        }
    }

    /// The wavefront shape used by `ripple(at:)`.
    public var revealMode: RevealMode = .radial

    /// Direction (radians) for the bars / venetian reveals.
    public var revealAngle: CGFloat = 0

    // -- stylize -------------------------------------------------------------

    /// RGB dispersion split for the frosted result, in points. 0 = off.
    public var chromaticAberration: CGFloat = 0

    /// Darkening of alternating scanlines, 0...1. 0 = off.
    public var scanlineStrength: CGFloat = 0

    /// Scanline period, in points.
    public var scanlineSpacing: CGFloat = 4

    public init() {}
}

// MARK: - Uniforms (must match StoneShaders.metal field order exactly)

private struct StoneUniforms {
    var resolution = SIMD2<Float>(0, 0)
    var contentScale = SIMD2<Float>(1, 1)

    var blurRadius: Float = 10
    var grain: Float = 0.5
    var distortion: Float = 0.55
    var translucency: Float = 1.4

    var surfaceScale: Float = 22
    var saturation: Float = 1.3
    var brightness: Float = 1
    var flipVertical: Float = 1

    var tint = SIMD4<Float>(0.35, 0.8, 1.0, 0.6)

    var time: Float = 0
    var rippleActive: Float = 0
    var rippleRadius: Float = 0
    var rippleEdge: Float = 0

    var rippleOrigin = SIMD2<Float>(0, 0)
    var ripplePush: Float = 0
    var rippleWidth: Float = 0

    var rippleWavelength: Float = 0
    var rippleDecay: Float = 0
    var rippleFade: Float = 0
    var revealFrom: Float = 0

    var revealTo: Float = 1
    var ripplePhase: Float = 0
    var material: Float = 0
    var revealMode: Float = 0

    var revealAngle: Float = 0
    var chromaticAberration: Float = 0
    var scanlineStrength: Float = 0
    var scanlineSpacing: Float = 4
}

// MARK: - StoneEffectView

/// The view that performs the effect. You normally create this through
/// `UIView.applyStone(...)` rather than instantiating it directly, but the
/// initializer is public if you want full control over placement.
public final class StoneEffectView: UIView {

    /// Live configuration. Mutate freely on the main thread.
    public var config: StoneConfig {
        didSet {
            if config != oldValue {
                updateOpaqueState()
                setNeedsRedraw()
            }
        }
    }

    /// The view whose content is being processed.
    public private(set) weak var sourceView: UIView?

    /// Set false to pause rendering (e.g. when offscreen) to save power.
    public var isRendering: Bool = true {
        didSet { displayLink?.isPaused = !isRendering }
    }

    /// Whether the dot effect is currently shown (vs. the raw, unmodified view).
    /// Toggled by `ripple(at:)`; the wave animates the transition between the two.
    public private(set) var effectVisible: Bool = true

    /// When true the effect becomes interactive and a tap on it fires a ripple from
    /// the touch point (toggling the effect on/off). When false the effect is a
    /// passive overlay that lets touches fall through to the UI beneath it.
    public var ripplesOnTap: Bool = false {
        didSet {
            guard ripplesOnTap != oldValue else { return }
            isUserInteractionEnabled = ripplesOnTap
            if ripplesOnTap {
                addGestureRecognizer(rippleTapRecognizer)
            } else {
                removeGestureRecognizer(rippleTapRecognizer)
            }
        }
    }

    private lazy var rippleTapRecognizer =
        UITapGestureRecognizer(target: self, action: #selector(handleRippleTap(_:)))

    @objc private func handleRippleTap(_ gesture: UITapGestureRecognizer) {
        ripple(at: gesture.location(in: self))
    }

    // Ripple transition state.
    private var rippleRunning = false
    private var rippleStart: CFTimeInterval = 0
    private var rippleDurationResolved: TimeInterval = 0
    private var rippleOriginPx = SIMD2<Float>(0, 0)
    private var rippleFrom: Float = 0
    private var rippleTo: Float = 1

    // Render gating (perf): only capture/draw when something changed or an
    // animation is in flight; otherwise the display link parks itself.
    private var needsCapture = true
    private var needsRender = true

    public override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    // Metal objects
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState!
    private var uniformBuffer: MTLBuffer!

    // Capture
    private var caRenderer: CARenderer?
    private var sourceTexture: MTLTexture?
    private var sourceSurface: IOSurfaceRef?
    private var sourceTextureSize: CGSize = .zero
    private var useCPUFallback = false

    // `nonisolated(unsafe)` so the (nonisolated) deinit can invalidate the link as a
    // teardown backstop; all other access is on the main actor.
    nonisolated(unsafe) private var displayLink: CADisplayLink?
    private var startTime = CACurrentMediaTime()

    /// True when the effect was attached as a child of the source because the
    /// source had no superview; it will reparent to a sibling once possible.
    fileprivate var awaitingReparent = false

    // MARK: Init

    /// Create an effect view bound to `source`. The effect view is sized to the
    /// source's bounds; keep it pinned over the source (the convenience API does
    /// this for you).
    public init?(source: UIView, config: StoneConfig = StoneConfig()) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.queue = queue
        self.config = config
        self.sourceView = source
        super.init(frame: source.bounds)

        self.isUserInteractionEnabled = false
        self.backgroundColor = .clear

        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        // We only ever render into the drawable and present it (never sample or read
        // it back), so the framebuffer-only fast path is safe and cheaper.
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.contentsScale = source.window?.screen.scale
            ?? UIScreen.main.scale

        guard buildPipeline() else { return nil }

        uniformBuffer = device.makeBuffer(length: MemoryLayout<StoneUniforms>.stride,
                                          options: .storageModeShared)

        startDisplayLink()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        displayLink?.invalidate()
    }

    // MARK: Pipeline

    private func buildPipeline() -> Bool {
        // Load the Metal library. When built as a SwiftPM target the `.metal` file is
        // compiled into a `default.metallib` inside this module's resource bundle
        // (`Bundle.module`) — even when the code itself is statically linked into the
        // host app, so `Bundle(for:)` would resolve to the app bundle and miss it.
        // Prefer `Bundle.module`, then the class bundle, then the system default.
        let library: MTLLibrary?
        if let lib = try? device.makeDefaultLibrary(bundle: .module) {
            library = lib
        } else if let lib = try? device.makeDefaultLibrary(bundle: Bundle(for: StoneEffectView.self)) {
            library = lib
        } else {
            library = device.makeDefaultLibrary()
        }
        guard let lib = library,
              let vfn = lib.makeFunction(name: "stone_vertex"),
              let ffn = lib.makeFunction(name: "stone_fragment") else {
            assertionFailure("StoneEffect: could not load Metal functions. " +
                             "Ensure StoneShaders.metal is in the target.")
            return false
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        let att = desc.colorAttachments[0]!
        att.pixelFormat = .bgra8Unorm
        // Premultiplied alpha blending so translucent gaps composite correctly.
        att.isBlendingEnabled = true
        att.rgbBlendOperation = .add
        att.alphaBlendOperation = .add
        att.sourceRGBBlendFactor = .one
        att.sourceAlphaBlendFactor = .one
        att.destinationRGBBlendFactor = .oneMinusSourceAlpha
        att.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
            return true
        } catch {
            assertionFailure("StoneEffect: pipeline error \(error)")
            return false
        }
    }

    // MARK: Display link

    private func startDisplayLink() {
        let link = CADisplayLink(target: StoneProxy(self), selector: #selector(StoneProxy.tick))
        // Run at the screen's native refresh rate (60 on most devices, 120 on
        // ProMotion) so the effect stays in lock-step with the live UI it mirrors.
        if #available(iOS 15.0, *) {
            let maxFPS = Float((window?.screen ?? UIScreen.main).maximumFramesPerSecond)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: maxFPS, preferred: maxFPS)
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Request one (or a few) more rendered frames and un-park the display link.
    /// Cheap to over-call; the link parks itself again once everything is idle.
    private func wake() {
        needsRender = true
        if isRendering { displayLink?.isPaused = false }
    }

    /// A config/parameter change only re-runs the shader on the cached frame.
    fileprivate func setNeedsRedraw() { wake() }

    /// Tell the effect the captured source content changed (new image, video frame,
    /// resize) so the next frame re-captures. Ripple animations deliberately do NOT
    /// trigger a re-capture — they only re-run the shader on the cached frame.
    public func setNeedsCapture() {
        needsCapture = true
        wake()
    }

    // MARK: Hit testing

    /// The effect is a purely visual overlay sitting on top of the live UI. Never
    /// intercept touches — let every gesture fall straight through to the real,
    /// interactive views underneath (which are what actually drive the content the
    /// effect re-renders each frame).
    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Interactive (ripple-on-tap) mode receives touches so the tap gesture can
        // fire; passive overlay mode is fully transparent to touches.
        ripplesOnTap ? super.hitTest(point, with: event) : nil
    }

    // MARK: Layout

    public override func layoutSubviews() {
        super.layoutSubviews()
        // Match the metal layer to our (point) bounds; resize capture resources.
        // Render at most at 2x: the coarse dot grid hides the difference from a 3x
        // backing while cutting the fragment shader's pixel count by ~55% there.
        let screenScale = window?.screen.scale ?? metalLayer.contentsScale
        let scale = min(screenScale, 2.0)
        metalLayer.contentsScale = scale
        let pixelSize = CGSize(width: (bounds.width * scale).rounded(),
                               height: (bounds.height * scale).rounded())
        if pixelSize.width > 0, pixelSize.height > 0 {
            metalLayer.drawableSize = pixelSize
            // Source is captured at POINT resolution (see captureSource rationale).
            ensureCaptureResources(pointSize: bounds.size)
        }
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        reparentToSiblingIfNeeded()
    }

    /// If we were attached as a child of the source (because it had no superview),
    /// move to a sibling position above it now that one is available. This avoids
    /// CARenderer capturing our own Metal layer and creating a feedback loop.
    private func reparentToSiblingIfNeeded() {
        guard awaitingReparent,
              let source = sourceView,
              superview === source,
              let parent = source.superview else { return }
        awaitingReparent = false
        removeFromSuperview()
        parent.insertSubview(self, aboveSubview: source)
        pinEdges(to: source)
    }

    fileprivate func pinEdges(to other: UIView) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor),
            trailingAnchor.constraint(equalTo: other.trailingAnchor),
            topAnchor.constraint(equalTo: other.topAnchor),
            bottomAnchor.constraint(equalTo: other.bottomAnchor),
        ])
    }

    // MARK: Capture resources

    private func ensureCaptureResources(pointSize: CGSize) {
        // Capture texture is sized in points (1x). Round up to whole pixels.
        let target = CGSize(width: pointSize.width.rounded(.up),
                            height: pointSize.height.rounded(.up))
        guard target != sourceTextureSize else { return }
        sourceTextureSize = target
        needsCapture = true   // a resized texture must be re-captured
        wake()

        let w = Int(target.width)
        let h = Int(target.height)
        guard w > 0, h > 0 else { return }

        // GPU capture: CARenderer renders the source layer tree into an IOSurface-
        // backed Metal texture (zero-copy, shared with the fragment shader). The
        // effect is only ever applied to a single-content stage (one image/video),
        // so CARenderer's per-layer content inversion is just a global vertical flip,
        // corrected by `sourceFlippedOverride = true` on the config.
        let props: [IOSurfacePropertyKey: Any] = [
            .width: w, .height: h, .bytesPerElement: 4,
            .pixelFormat: kCVPixelFormatType_32BGRA,
        ]
        guard let surface = IOSurfaceCreate(props as CFDictionary) else {
            useCPUFallback = true
            buildCPUFallbackTexture(w: w, h: h)
            return
        }
        sourceSurface = surface

        let td = MTLTextureDescriptor()
        td.pixelFormat = .bgra8Unorm
        td.width = w
        td.height = h
        td.usage = [.shaderRead, .renderTarget]
        td.storageMode = .shared

        guard let tex = device.makeTexture(descriptor: td, iosurface: surface, plane: 0) else {
            useCPUFallback = true
            buildCPUFallbackTexture(w: w, h: h)
            return
        }
        sourceTexture = tex

        // Detach the outgoing renderer's captured layer before it's released — a
        // CALayer can only root one CARenderer, so reassigning it across renderers
        // otherwise leaves a dangling association (use-after-free).
        caRenderer?.layer = nil

        let renderer = CARenderer(mtlTexture: tex, options: nil)
        renderer.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        caRenderer = renderer
        useCPUFallback = false
    }

    private func buildCPUFallbackTexture(w: Int, h: Int) {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                          width: w, height: h,
                                                          mipmapped: false)
        td.usage = [.shaderRead]
        td.storageMode = .shared
        sourceTexture = device.makeTexture(descriptor: td)
    }

    // MARK: Frame

    fileprivate func renderFrame() {
        guard isRendering, let source = sourceView else { return }

        // Park the display link when nothing needs drawing: no wave in flight, no
        // pending content/config change. This is the main power/heat win — a settled
        // frosted image costs nothing once the ripple has finished.
        guard rippleRunning || needsRender || needsCapture else {
            displayLink?.isPaused = true
            return
        }

        // Re-capture the source only when its content actually changed; the ripple
        // animation reuses the cached texture and just re-runs the fragment shader.
        if needsCapture {
            if captureSource(source) { needsCapture = false }
        }
        guard let srcTex = sourceTexture else { return }

        guard let drawable = metalLayer.nextDrawable() else { return }

        updateUniforms(drawableSize: metalLayer.drawableSize, sourceSize: srcTex.sizeCG)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(srcTex, index: 0)
        enc.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()

        cmd.present(drawable)
        cmd.commit()

        needsRender = false
        // Once the latest state is on screen and nothing is animating, park.
        if !rippleRunning && !needsCapture {
            displayLink?.isPaused = true
        }
    }

    /// Render the source layer tree into `sourceTexture`. Returns true on success.
    ///
    /// Capture happens in POINT space (texture sized to the source's point bounds).
    /// That's deliberate: the effect down-samples the content into large grid cells,
    /// so capturing at 1x instead of 2x/3x is visually indistinguishable while
    /// cutting capture cost by 4-9x — a big win on older GPUs. The on-screen dots
    /// are still rendered at full device resolution by the Metal layer.
    private func captureSource(_ source: UIView) -> Bool {
        guard let tex = sourceTexture else { return false }

        if !useCPUFallback, let renderer = caRenderer {
            // GPU path — CARenderer reads presentation-layer state, so in-flight
            // Core Animation animations are captured frame-accurately.

            // Clear the capture texture first. CARenderer composites *over* existing
            // contents and won't touch fully-transparent regions, so without a clear
            // old frames bleed through where the new frame is transparent.
            if let clearCmd = queue.makeCommandBuffer() {
                let cp = MTLRenderPassDescriptor()
                cp.colorAttachments[0].texture = tex
                cp.colorAttachments[0].loadAction = .clear
                cp.colorAttachments[0].storeAction = .store
                cp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                clearCmd.makeRenderCommandEncoder(descriptor: cp)?.endEncoding()
                clearCmd.commit()
            }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if renderer.layer !== source.layer {
                renderer.layer = source.layer
            }
            renderer.bounds = CGRect(origin: .zero, size: tex.sizeCG)
            CATransaction.commit()

            let now = CACurrentMediaTime()
            renderer.beginFrame(atTime: now, timeStamp: nil)
            // Mark the whole frame dirty; without an update region CARenderer can
            // skip drawing entirely (notably the first frame).
            renderer.addUpdate(renderer.bounds)
            renderer.render()
            renderer.endFrame()
            return true
        } else {
            // CPU fallback — snapshot of the presentation tree (animation-correct).
            return cpuSnapshot(source: source, into: tex)
        }
    }

    private var cpuContext: CGContext?
    private func cpuSnapshot(source: UIView, into tex: MTLTexture) -> Bool {
        let w = tex.width, h = tex.height
        let bytesPerRow = w * 4
        if cpuContext == nil || cpuContext?.width != w || cpuContext?.height != h {
            let cs = CGColorSpaceCreateDeviceRGB()
            cpuContext = CGContext(data: nil, width: w, height: h,
                                   bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                   space: cs,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                               CGBitmapInfo.byteOrder32Little.rawValue)
        }
        guard let ctx = cpuContext, let data = ctx.data else { return false }

        // Texture is point-sized (see captureSource), so render at 1x.
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        // Prefer the presentation layer so ongoing animations are captured.
        let layerToRender = source.layer.presentation() ?? source.layer
        layerToRender.render(in: ctx)
        ctx.restoreGState()

        tex.replace(region: MTLRegionMake2D(0, 0, w, h),
                    mipmapLevel: 0,
                    withBytes: data,
                    bytesPerRow: bytesPerRow)
        return true
    }

    // MARK: Uniforms

    private func updateUniforms(drawableSize: CGSize, sourceSize: CGSize) {
        var u = StoneUniforms()
        let scale = Float(metalLayer.contentsScale)

        u.resolution = SIMD2(Float(drawableSize.width), Float(drawableSize.height))
        // Source texture is the same pixel size as the drawable in our setup.
        u.contentScale = SIMD2(1, 1)

        u.blurRadius = Float(config.blurRadius) * scale
        u.grain = Float(config.grain)
        u.distortion = Float(config.distortion)
        u.translucency = Float(config.translucency)
        u.surfaceScale = Float(config.surfaceScale) * scale
        u.saturation = Float(config.saturation)
        u.brightness = Float(config.brightness)
        u.tint = config.tint.straightSimd4
        u.material = Float(config.material.rawValue)   // 0 jellystone, 1 luna
        u.revealMode = Float(config.revealMode.rawValue)
        u.revealAngle = Float(config.revealAngle)
        u.chromaticAberration = Float(config.chromaticAberration) * scale
        u.scanlineStrength = Float(config.scanlineStrength)
        u.scanlineSpacing = max(Float(config.scanlineSpacing) * scale, 2)
        u.time = Float(CACurrentMediaTime() - startTime)

        // The effect only ever captures a single-content stage via CARenderer, whose
        // per-layer content inversion is a plain global vertical flip here — undo it
        // unless an explicit override says otherwise.
        let flipped = config.sourceFlippedOverride ?? true
        u.flipVertical = flipped ? 1 : 0

        applyRippleUniforms(to: &u, scale: scale)

        uniformBuffer.contents().copyMemory(from: &u,
                                            byteCount: MemoryLayout<StoneUniforms>.stride)
    }

    /// Fills in the ripple-transition fields. When no wave is in flight the effect
    /// is shown (or hidden) uniformly per `effectVisible`; while a wave is running
    /// the wavefront cross-fades between the two states and pushes the dots out.
    private func applyRippleUniforms(to u: inout StoneUniforms, scale: Float) {
        if rippleRunning {
            let elapsed = CACurrentMediaTime() - rippleStart
            if elapsed >= rippleDurationResolved {
                rippleRunning = false
                effectVisible = rippleTo >= 0.5
            } else {
                let speedPx = Float(config.rippleSpeed) * scale
                u.rippleActive = 1
                u.rippleRadius = speedPx * Float(elapsed)
                u.rippleOrigin = rippleOriginPx
                u.ripplePush = Float(config.ripplePushDistance) * scale
                u.rippleWidth = Float(config.rippleWidth) * scale
                u.rippleEdge = max(Float(config.rippleEdge) * scale, 0.75)
                u.rippleWavelength = Float(config.rippleWavelength) * scale
                u.rippleDecay = Float(config.rippleDecay) * scale
                u.revealFrom = rippleFrom
                u.revealTo = rippleTo
                let p = rippleDurationResolved > 0 ? Float(elapsed / rippleDurationResolved) : 1
                // Ease the amplitude to zero over the last quarter so nothing snaps.
                u.rippleFade = 1 - smoothstepf(0.75, 1.0, p)
            }
        }
        if !rippleRunning {
            u.rippleActive = 0
            u.revealTo = effectVisible ? 1 : 0
            u.revealFrom = u.revealTo
            u.rippleFade = 0
        }
    }

    /// The frosted-neon output is always opaque, so let the compositor skip blending
    /// the covered source underneath.
    fileprivate func updateOpaqueState() {
        metalLayer.isOpaque = true
        isOpaque = true
    }

    // MARK: Ripple transition

    /// Animate the effect on or off with a wave emanating from `point` (in this
    /// view's coordinate space). The wavefront flips the dots into/out of
    /// existence and pushes them radially outward before they settle back.
    ///
    /// - Parameters:
    ///   - point: the origin of the wave, in points.
    ///   - reveal: `true` animates the effect *on*, `false` animates it *off*,
    ///     `nil` toggles the current state.
    /// - Returns: the resulting `effectVisible` state.
    @discardableResult
    public func ripple(at point: CGPoint, reveal: Bool? = nil) -> Bool {
        let target = reveal ?? !effectVisible
        let scale = CGFloat(metalLayer.contentsScale)
        rippleOriginPx = SIMD2(Float(point.x * scale), Float(point.y * scale))
        rippleFrom = effectVisible ? 1 : 0
        rippleTo = target ? 1 : 0

        // Auto-fit the duration so the wavefront just clears the farthest corner,
        // unless the caller pinned an explicit duration.
        if config.rippleDuration > 0 {
            rippleDurationResolved = config.rippleDuration
        } else {
            let b = bounds.size
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: b.width, y: 0),
                           CGPoint(x: 0, y: b.height), CGPoint(x: b.width, y: b.height)]
            let maxDist = corners.map { hypot($0.x - point.x, $0.y - point.y) }.max()
                ?? max(b.width, b.height)
            let speed = max(config.rippleSpeed, 1)
            // Time for the front (plus its soft edge) to clear the farthest corner.
            rippleDurationResolved = Double((maxDist + config.rippleWidth + config.rippleEdge) / speed)
        }

        rippleStart = CACurrentMediaTime()
        rippleRunning = true
        wake()
        return target
    }

    // MARK: Public control

    /// Remove the effect and restore the source view.
    public func remove() {
        displayLink?.invalidate()
        displayLink = nil
        caRenderer?.layer = nil
        caRenderer = nil
        sourceView?.stoneEffect = nil
        removeFromSuperview()
    }
}

// MARK: - Display link proxy (avoids retain cycle)

private final class StoneProxy {
    weak var target: StoneEffectView?
    init(_ t: StoneEffectView) { target = t }
    @objc func tick() { target?.renderFrame() }
}

// MARK: - Small helpers

/// Scalar smoothstep matching the GLSL/Metal semantics.
private func smoothstepf(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)
}

private extension MTLTexture {
    var sizeCG: CGSize { CGSize(width: width, height: height) }
}

private extension UIColor {
    /// Straight (non-premultiplied) RGBA. Alpha carries the tint strength.
    var straightSimd4: SIMD4<Float> {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if getRed(&r, green: &g, blue: &b, alpha: &a) {
            return SIMD4(Float(r), Float(g), Float(b), Float(a))
        }
        return SIMD4(0, 0, 0, 0)
    }
}

// MARK: - UIView convenience API

// Only ever used as a stable address for `objc_setAssociatedObject`, never read
// or written as a value, so unchecked global mutable state is safe here.
nonisolated(unsafe) private var stoneKey: UInt8 = 0

public extension UIView {

    /// The active stone effect on this view, if any.
    internal(set) var stoneEffect: StoneEffectView? {
        get { objc_getAssociatedObject(self, &stoneKey) as? StoneEffectView }
        set { objc_setAssociatedObject(self, &stoneKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Apply the stone effect to this view. The effect view is placed directly
    /// over this view (as a sibling) and re-renders this view's content through the
    /// stone shader every frame, so animations on this view and its subviews
    /// flow through the effect automatically.
    ///
    /// The source view is NOT hidden (the effect needs it rendering to capture it);
    /// it's simply covered. For best results the view should be in a view hierarchy.
    ///
    /// - Returns: the created effect view, or nil if Metal is unavailable.
    @discardableResult
    func applyStone(_ config: StoneConfig = StoneConfig()) -> StoneEffectView? {
        removeStone()

        guard let effect = StoneEffectView(source: self, config: config) else {
            return nil
        }

        // Pin the effect over us. Preferred placement is as a SIBLING above us, so
        // CARenderer (which captures our whole layer tree) never sees the effect's
        // own Metal layer — that would feed the output back into the input.
        effect.translatesAutoresizingMaskIntoConstraints = false
        if let parent = superview {
            parent.insertSubview(effect, aboveSubview: self)
            effect.pinEdges(to: self)
        } else {
            // No superview yet: attach as a child for now and mark it so the effect
            // reparents to a sibling as soon as we're added to a hierarchy (avoids
            // the capture-feedback loop described above).
            addSubview(effect)
            effect.pinEdges(to: self)
            effect.awaitingReparent = true
        }

        // We intentionally do NOT hide the source view. Hiding sets the layer's
        // `isHidden`, which CARenderer also honours — it would capture nothing.
        // Instead the effect view sits directly on top: the shader's output fully
        // covers the source (translucency in the effect is the shader's own,
        // deliberate look). The source still drives layout and
        // animation normally, feeding the capture every frame.
        effect.updateOpaqueState()

        stoneEffect = effect
        return effect
    }

    /// Builder-style variant.
    @discardableResult
    func applyStone(_ build: (inout StoneConfig) -> Void) -> StoneEffectView? {
        var c = StoneConfig()
        build(&c)
        return applyStone(c)
    }

    /// Apply the effect to `self` (the layout host) while capturing a *different*
    /// `source` view's content. The effect is pinned to `self`, so `self` stays a
    /// normal, layout-stable view. See the Dot Matrix equivalent for why the captured
    /// view must not be the one that owns layout constraints (CARenderer orphans it).
    @discardableResult
    func applyStone(_ config: StoneConfig = StoneConfig(), capturing source: UIView) -> StoneEffectView? {
        removeStone()
        guard let effect = StoneEffectView(source: source, config: config) else { return nil }
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)
        effect.pinEdges(to: self)   // pinned to the host, not the captured source
        effect.updateOpaqueState()
        stoneEffect = effect
        return effect
    }

    /// Remove any stone effect from this view.
    func removeStone() {
        stoneEffect?.remove()
        stoneEffect = nil
    }
}

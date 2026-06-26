//
//  HalftoneEffectView.swift
//  HalftoneEffect
//
//  A standalone, drop-in UIKit component that applies a real-time "dot-matrix /
//  halftone" effect to ANY UIView and everything it contains (including live
//  Core Animation animations), with a Metal pipeline that stays smooth on older
//  hardware.
//
//  ---------------------------------------------------------------------------
//  USAGE
//  ---------------------------------------------------------------------------
//
//      // One line:
//      let effect = someView.applyHalftone()
//
//      // …or configured:
//      let effect = imageView.applyHalftone { c in
//          c.cellSize     = 14
//          c.dotScale     = 0.82
//          c.cornerRadius = 0.28      // 0 = square, 1 = circle
//          c.gapColor     = .black
//          c.gapBlur      = 0         // blur the space between dots
//          c.gapSourceMix = 0
//      }
//
//      // Tweak live (animatable values just assign):
//      effect.config.cellSize = 22
//
//      // Remove:
//      effect.remove()                // or imageView.removeHalftone()
//
//  Drop `HalftoneEffectView.swift` + `HalftoneShaders.metal` into your target.
//  No other files required. iOS 13+.
//
//  ---------------------------------------------------------------------------
//  HOW IT WORKS  (why it's fast)
//  ---------------------------------------------------------------------------
//  The effect view is added as a sibling sitting on top of the target view. Each
//  display-link tick we render the TARGET LAYER'S TREE into an IOSurface-backed
//  Metal texture using `CARenderer`. CARenderer composites on the GPU and reads
//  *presentation* layer state, so in-flight implicit/explicit Core Animation
//  animations are captured frame-accurately without any CPU snapshotting. That
//  texture is then fed to a fragment shader that does the dot-matrix sampling in
//  one pass. The host view itself is hidden from the screen (its content only
//  lives in our texture) so you don't pay to draw it twice.
//
//  If CARenderer is unavailable for some reason, we transparently fall back to a
//  CPU snapshot path so the effect still works (just less ideal for heavy anims).
//

import UIKit
import Metal
import QuartzCore
import simd

// MARK: - Configuration

/// All tunable parameters of the effect. Assigning any property updates the
/// effect on the next frame. Safe to mutate from the main thread at any time.
public struct HalftoneConfig: Equatable {

    public enum DotShape: Equatable {
        case circle
        case square
        case roundedSquare(cornerRadius: CGFloat)   // 0...1 of the dot half-size
        /// Provide your own corner radius fraction directly.
        case custom(cornerFraction: CGFloat)
    }

    /// Center-to-center spacing of the grid, in points. Smaller = finer dots.
    public var cellSize: CGFloat = 16

    /// Dot size as a fraction of the base cell. Can exceed 1 when `dotSpacing` > 1.
    public var dotScale: CGFloat = 0.82

    /// Grid-pitch multiplier (>= 1). The dot keeps the size set by `cellSize` ×
    /// `dotScale`; increasing this spreads the dots further apart without resizing
    /// them.
    public var dotSpacing: CGFloat = 1.0

    /// Shape of the dot. Internally converted to a corner-radius fraction.
    public var shape: DotShape = .roundedSquare(cornerRadius: 0.30)

    /// Edge antialiasing in points. ~1 is crisp; raise for softer dots.
    public var edgeSoftness: CGFloat = 1.0

    /// Positional jitter, 0...1. Adds organic randomness to dot centers.
    public var jitter: CGFloat = 0.0

    /// Multiplies the sampled dot color. >1 gives a brighter, blooming pop.
    public var brightnessBoost: CGFloat = 1.0

    /// If true, each dot is a small multi-tap average of its cell (smoother).
    /// If false, a single bilinear tap at the cell center (sharper, cheaper).
    public var averageCell: Bool = true

    /// If true, the sampled dot colors are converted to greyscale (luminance).
    public var monochrome: Bool = false

    /// If true, the "non-dot" view (and the gaps) are transparent instead of the
    /// raw image, so the ripple toggles the dots appearing/disappearing over
    /// nothing rather than crossfading to the unmodified content.
    public var transparentBackground: Bool = false

    /// Overall opacity of the dots, 0...1.
    public var dotOpacity: CGFloat = 1.0

    /// Rotation of the whole grid, in radians.
    public var gridAngle: CGFloat = 0.0

    /// Advanced: whether the captured source needs a vertical flip. Leave nil to
    /// let the effect choose automatically based on the capture path (GPU capture
    /// is flipped, CPU snapshot is not). Set explicitly only if you see the image
    /// upside-down on a particular OS version.
    public var sourceFlippedOverride: Bool? = nil

    // -- the "obscured space between the dots" ------------------------------

    /// Color shown in the gaps between dots. Use a translucent color to let the
    /// real background show through.
    public var gapColor: UIColor = .black

    /// Blur radius (points) sampled from the source to fill the gaps. 0 = off.
    /// Only has visible effect when `gapSourceMix` > 0.
    public var gapBlur: CGFloat = 0.0

    /// 0 = gaps are pure `gapColor`; 1 = gaps show a blurred version of the
    /// source content; in between blends the two.
    public var gapSourceMix: CGFloat = 0.0

    // -- ripple transition (animates the effect on/off from a tap point) -----

    /// Peak radial distance, in points, the dots are pushed out at the wavefront.
    public var ripplePushDistance: CGFloat = 24

    /// Speed of the expanding wavefront, in points per second.
    public var rippleSpeed: CGFloat = 1400

    /// Half-thickness, in points, of the Gaussian push ring.
    public var rippleWidth: CGFloat = 60

    /// Softness, in points, of the reveal step at the wavefront (the dots fade
    /// between on/off over this band).
    public var rippleEdge: CGFloat = 24

    /// Wavelength, in points, of the dispersive trailing ripples. 0 disables the
    /// oscillation and leaves a single clean Gaussian ring.
    public var rippleWavelength: CGFloat = 70

    /// e-folding length, in points, over which the trailing ripples die out.
    public var rippleDecay: CGFloat = 120

    /// Total duration of the transition, in seconds. 0 auto-fits to the view so
    /// the wavefront just clears the farthest corner.
    public var rippleDuration: TimeInterval = 0

    // -- finger drag (dots follow the touch, springing back) -----------------

    /// Influence radius, in points, of a finger drag. 0 disables the drag effect.
    public var dragRadius: CGFloat = 90

    /// How strongly the dragged dots follow the finger, 0...1+.
    public var dragStrength: CGFloat = 1.0

    /// Maximum distance, in points, the dots are carried before they slip and
    /// settle back (the "current can only drag them so far").
    public var dragMaxDistance: CGFloat = 70

    public init() {}

    // Convenience presets ---------------------------------------------------

    /// The reference "LED flower" look: rounded squares on near-black.
    public static var ledPanel: HalftoneConfig {
        var c = HalftoneConfig()
        c.cellSize = 16
        c.dotScale = 0.84
        c.shape = .roundedSquare(cornerRadius: 0.30)
        c.gapColor = .black
        c.averageCell = true
        c.brightnessBoost = 1.04
        return c
    }

    /// Classic round-dot halftone.
    public static var dots: HalftoneConfig {
        var c = HalftoneConfig()
        c.cellSize = 12
        c.dotScale = 0.9
        c.shape = .circle
        c.gapColor = .black
        return c
    }

    /// Frosted gaps: gaps show a blurred version of the content.
    public static var frosted: HalftoneConfig {
        var c = HalftoneConfig()
        c.cellSize = 18
        c.dotScale = 0.8
        c.shape = .roundedSquare(cornerRadius: 0.35)
        c.gapColor = UIColor.black.withAlphaComponent(0.35)
        c.gapBlur = 8
        c.gapSourceMix = 0.7
        return c
    }

    fileprivate var cornerFraction: CGFloat {
        switch shape {
        case .circle:                       return 1.0
        case .square:                       return 0.0
        case .roundedSquare(let r):         return max(0, min(1, r))
        case .custom(let f):                return max(0, min(1, f))
        }
    }
}

// MARK: - Uniforms (must match HalftoneShaders.metal exactly)

private struct HalftoneUniforms {
    var resolution = SIMD2<Float>(0, 0)
    var contentScale = SIMD2<Float>(1, 1)

    var cellSize: Float = 16
    var dotScale: Float = 0.82
    var cornerRadius: Float = 0.30
    var edgeSoftness: Float = 1.0

    var dotSpacing: Float = 1
    var jitter: Float = 0
    var brightnessBoost: Float = 1
    var sampleAverage: Float = 1

    var gapColor = SIMD4<Float>(0, 0, 0, 1)
    var gapBlur: Float = 0
    var gapSourceMix: Float = 0
    var dotOpacity: Float = 1
    var time: Float = 0

    var gridAngle: Float = 0
    var flipVertical: Float = 1
    var rippleActive: Float = 0
    var rippleRadius: Float = 0

    var rippleOrigin = SIMD2<Float>(0, 0)
    var ripplePush: Float = 0
    var rippleWidth: Float = 0

    var rippleEdge: Float = 0
    var rippleWavelength: Float = 0
    var rippleDecay: Float = 0
    var rippleFade: Float = 0

    var revealFrom: Float = 0
    var revealTo: Float = 1
    var ripplePhase: Float = 0
    var monochrome: Float = 0

    var dragOrigin = SIMD2<Float>(0, 0)
    var transparentBackground: Float = 0
    var dragRadius: Float = 0

    var dragVector = SIMD2<Float>(0, 0)
    var _pad0: Float = 0
    var _pad1: Float = 0
}

// MARK: - HalftoneEffectView

/// The view that performs the effect. You normally create this through
/// `UIView.applyHalftone(...)` rather than instantiating it directly, but the
/// initializer is public if you want full control over placement.
public final class HalftoneEffectView: UIView {

    /// Live configuration. Mutate freely on the main thread.
    public var config: HalftoneConfig {
        didSet {
            if config != oldValue {
                updateOpaqueState()
                wake()   // re-render the new look (no re-capture needed)
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
                addGestureRecognizer(rippleDragRecognizer)
            } else {
                removeGestureRecognizer(rippleTapRecognizer)
                removeGestureRecognizer(rippleDragRecognizer)
            }
        }
    }

    private lazy var rippleTapRecognizer =
        UITapGestureRecognizer(target: self, action: #selector(handleRippleTap(_:)))

    private lazy var rippleDragRecognizer =
        UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))

    @objc private func handleRippleTap(_ gesture: UITapGestureRecognizer) {
        ripple(at: gesture.location(in: self))
    }

    @objc private func handleDrag(_ gesture: UIPanGestureRecognizer) {
        let scale = CGFloat(metalLayer.contentsScale)
        switch gesture.state {
        case .began, .changed:
            dragActive = true
            let loc = gesture.location(in: self)
            dragOriginPx = SIMD2(Float(loc.x * scale), Float(loc.y * scale))
            let t = gesture.translation(in: self)
            var v = SIMD2(Float(t.x * scale), Float(t.y * scale)) * Float(config.dragStrength)
            // Cap how far the "current" can carry the dots before they slip.
            let maxPx = Float(config.dragMaxDistance * scale)
            let len = (v.x * v.x + v.y * v.y).squareRoot()
            if len > maxPx, len > 0 { v *= maxPx / len }
            dragTargetPx = v
            wake()
        case .ended, .cancelled, .failed:
            dragTargetPx = .zero   // release: the dots spring back to rest
            wake()
        default:
            break
        }
    }

    /// Critically-damped-ish follow of the drag displacement toward its target, so
    /// the dots lag behind the finger (viscous) and spring back on release.
    private func stepDrag() {
        guard dragActive else { return }
        dragVectorPx += (dragTargetPx - dragVectorPx) * 0.35
        let restLen = (dragVectorPx.x * dragVectorPx.x + dragVectorPx.y * dragVectorPx.y).squareRoot()
        if dragTargetPx == .zero, restLen < 0.5 {
            dragVectorPx = .zero
            dragActive = false
        }
    }

    // Ripple transition state.
    private var rippleRunning = false
    private var rippleStart: CFTimeInterval = 0
    private var rippleDurationResolved: TimeInterval = 0
    private var rippleOriginPx = SIMD2<Float>(0, 0)
    private var rippleFrom: Float = 0
    private var rippleTo: Float = 1

    // Finger-drag state.
    private var dragActive = false
    private var dragOriginPx = SIMD2<Float>(0, 0)
    private var dragVectorPx = SIMD2<Float>(0, 0)
    private var dragTargetPx = SIMD2<Float>(0, 0)

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
    public init?(source: UIView, config: HalftoneConfig = .ledPanel) {
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

        uniformBuffer = device.makeBuffer(length: MemoryLayout<HalftoneUniforms>.stride,
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
        } else if let lib = try? device.makeDefaultLibrary(bundle: Bundle(for: HalftoneEffectView.self)) {
            library = lib
        } else {
            library = device.makeDefaultLibrary()
        }
        guard let lib = library,
              let vfn = lib.makeFunction(name: "halftone_vertex"),
              let ffn = lib.makeFunction(name: "halftone_fragment") else {
            assertionFailure("HalftoneEffect: could not load Metal functions. " +
                             "Ensure HalftoneShaders.metal is in the target.")
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
            assertionFailure("HalftoneEffect: pipeline error \(error)")
            return false
        }
    }

    // MARK: Display link

    private func startDisplayLink() {
        let link = CADisplayLink(target: HalftoneProxy(self), selector: #selector(HalftoneProxy.tick))
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

    /// Tell the effect the captured source content changed (new image, video frame,
    /// resize) so the next frame re-captures. Animations (ripple/drag) deliberately
    /// do NOT trigger a re-capture — they only re-run the shader on the cached frame.
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

        // Park the display link when nothing needs drawing: no animation in flight,
        // no pending content/config change. This is the main power/heat win — a
        // static dotted image costs nothing once it has settled.
        let animating = rippleRunning || dragActive
        guard animating || needsRender || needsCapture else {
            displayLink?.isPaused = true
            return
        }

        // Advance the springy drag before sampling its state into the uniforms.
        stepDrag()

        // Re-capture the source only when its content actually changed; ripple/drag
        // animations reuse the cached texture and just re-run the fragment shader.
        if needsCapture {
            if captureSource(source) { needsCapture = false }
        }
        guard let srcTex = sourceTexture, let drawable = metalLayer.nextDrawable() else { return }

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
        if !animating && !needsCapture {
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
        var u = HalftoneUniforms()
        let scale = Float(metalLayer.contentsScale)

        u.resolution = SIMD2(Float(drawableSize.width), Float(drawableSize.height))
        // Source texture is the same pixel size as the drawable in our setup.
        u.contentScale = SIMD2(1, 1)

        u.cellSize = Float(config.cellSize) * scale
        u.dotScale = Float(config.dotScale)
        u.dotSpacing = Float(max(config.dotSpacing, 1))
        u.cornerRadius = Float(config.cornerFraction)
        u.edgeSoftness = Float(config.edgeSoftness) * scale
        u.jitter = Float(config.jitter)
        u.brightnessBoost = Float(config.brightnessBoost)
        u.sampleAverage = config.averageCell ? 1 : 0
        u.monochrome = config.monochrome ? 1 : 0
        u.transparentBackground = config.transparentBackground ? 1 : 0
        u.dotOpacity = Float(config.dotOpacity)
        u.gridAngle = Float(config.gridAngle)
        u.time = Float(CACurrentMediaTime() - startTime)

        u.gapColor = config.gapColor.simd4
        u.gapBlur = Float(config.gapBlur) * scale
        u.gapSourceMix = Float(config.gapSourceMix)

        // Finger drag (springy displacement of nearby dots toward the touch).
        u.dragOrigin = dragOriginPx
        u.dragVector = dragVectorPx
        u.dragRadius = dragActive ? Float(config.dragRadius) * scale : 0

        // On iOS, CARenderer captures the layer tree in UIKit's top-left orientation,
        // and the CPU snapshot path flips in its own CGContext, so neither path needs
        // an extra vertical flip — adding one mirrors the content top-to-bottom (which
        // also makes the live UI underneath appear untappable, since what you see no
        // longer lines up with the real, hit-testable views). Honour an explicit
        // override only if a particular OS build still looks inverted.
        let flipped = config.sourceFlippedOverride ?? false
        u.flipVertical = flipped ? 1 : 0

        applyRippleUniforms(to: &u, scale: scale)

        uniformBuffer.contents().copyMemory(from: &u,
                                            byteCount: MemoryLayout<HalftoneUniforms>.stride)
    }

    /// Fills in the ripple-transition fields. When no wave is in flight the effect
    /// is shown (or hidden) uniformly per `effectVisible`; while a wave is running
    /// the wavefront cross-fades between the two states and pushes the dots out.
    private func applyRippleUniforms(to u: inout HalftoneUniforms, scale: Float) {
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

    /// Sets the Metal layer opaque iff the gap color is fully opaque, so the
    /// compositor can skip blending the (covered) source underneath — a free perf
    /// win for the common black-gap case.
    fileprivate func updateOpaqueState() {
        var a: CGFloat = 0
        config.gapColor.getRed(nil, green: nil, blue: nil, alpha: &a)
        let fullyOpaque = !config.transparentBackground && (a >= 0.999)
            && config.dotOpacity >= 0.999 && config.gapSourceMix < 0.001
        metalLayer.isOpaque = fullyOpaque
        isOpaque = fullyOpaque
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
        sourceView?.halftoneEffect = nil
        removeFromSuperview()
    }
}

// MARK: - Display link proxy (avoids retain cycle)

private final class HalftoneProxy {
    weak var target: HalftoneEffectView?
    init(_ t: HalftoneEffectView) { target = t }
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
    var simd4: SIMD4<Float> {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if getRed(&r, green: &g, blue: &b, alpha: &a) {
            // premultiply for the blend setup
            return SIMD4(Float(r * a), Float(g * a), Float(b * a), Float(a))
        }
        return SIMD4(0, 0, 0, 1)
    }
}

// MARK: - UIView convenience API

// Only ever used as a stable address for `objc_setAssociatedObject`, never read
// or written as a value, so unchecked global mutable state is safe here.
nonisolated(unsafe) private var halftoneKey: UInt8 = 0

public extension UIView {

    /// The active halftone effect on this view, if any.
    internal(set) var halftoneEffect: HalftoneEffectView? {
        get { objc_getAssociatedObject(self, &halftoneKey) as? HalftoneEffectView }
        set { objc_setAssociatedObject(self, &halftoneKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Apply the halftone effect to this view. The effect view is placed directly
    /// over this view (as a sibling) and re-renders this view's content through the
    /// dot-matrix shader every frame, so animations on this view and its subviews
    /// flow through the effect automatically.
    ///
    /// The source view is NOT hidden (the effect needs it rendering to capture it);
    /// it's simply covered. For best results the view should be in a view hierarchy.
    ///
    /// - Returns: the created effect view, or nil if Metal is unavailable.
    @discardableResult
    func applyHalftone(_ config: HalftoneConfig = .ledPanel) -> HalftoneEffectView? {
        removeHalftone()

        guard let effect = HalftoneEffectView(source: self, config: config) else {
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
        // Instead the effect view sits directly on top. When `gapColor` is opaque
        // the dots + gaps fully cover the source, so it's not visible on screen;
        // when `gapColor` is translucent, the source shows faintly through the gaps,
        // which is the intended "frosted" look. The source still drives layout and
        // animation normally, feeding the capture every frame.
        effect.updateOpaqueState()

        halftoneEffect = effect
        return effect
    }

    /// Builder-style variant.
    @discardableResult
    func applyHalftone(_ build: (inout HalftoneConfig) -> Void) -> HalftoneEffectView? {
        var c = HalftoneConfig.ledPanel
        build(&c)
        return applyHalftone(c)
    }

    /// Remove any halftone effect from this view.
    func removeHalftone() {
        halftoneEffect?.remove()
        halftoneEffect = nil
    }
}
